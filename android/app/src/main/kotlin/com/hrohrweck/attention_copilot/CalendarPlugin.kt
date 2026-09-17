package com.hrohrweck.attention_copilot

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Read-only Android CalendarContract adapter (plan todo 12).
 *
 * Exposes, over `MethodChannel("attention_copilot/calendar")`:
 *  * `hasPermission()` - whether `READ_CALENDAR` is currently granted;
 *  * `requestPermission()` - runtime permission request; completes with the
 *    grant decision (delivered through the `ActivityPluginBinding`
 *    request-permissions-result listener);
 *  * `listCalendars()` - the visible device calendars;
 *  * `listInstances(fromMillis, toMillis)` - occurrences in the window,
 *    read from `CalendarContract.Instances.CONTENT_URI` (pre-expanded
 *    recurrences) via `ContentUris.appendId(begin, end)`.
 *
 * All `ContentResolver` work runs on a single background executor:
 * provider queries are blocking and must never touch the platform thread.
 * Results are posted back on the main looper. The provider is strictly
 * read-only - this plugin never mutates calendar data.
 */
class CalendarPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware {

    companion object {
        const val CHANNEL = "attention_copilot/calendar"
        private const val REQUEST_CODE_READ_CALENDAR = 0xC4
    }

    private var channel: MethodChannel? = null
    private var applicationContext: Context? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * `ActivityAware` has no `onRequestPermissionsResult` callback; the grant
     * decision arrives through the binding's request-permissions-result
     * listener, which resolves the pending channel result.
     */
    private val permissionResultListener =
        object : ActivityPluginBinding.RequestPermissionsResultListener {
            override fun onRequestPermissionsResult(
                requestCode: Int,
                permissions: Array<String>,
                grantResults: IntArray,
            ): Boolean {
                if (requestCode != REQUEST_CODE_READ_CALENDAR) {
                    return false
                }
                val result = pendingPermissionResult ?: return false
                pendingPermissionResult = null
                val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
                result.success(granted)
                return true
            }
        }

    // ------------------------------------------------------------------ //
    // FlutterPlugin                                                       //
    // ------------------------------------------------------------------ //

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        applicationContext = null
        pendingPermissionResult = null
        executor.shutdown()
    }

    // ------------------------------------------------------------------ //
    // ActivityAware - only `requestPermission` needs the Activity. The    //
    // grant decision is delivered through the binding's                   //
    // request-permissions-result listener registered below.               //
    // ------------------------------------------------------------------ //

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addRequestPermissionsResultListener(permissionResultListener)
    }

    override fun onReattachedToActivityForConfigChanges(
        binding: ActivityPluginBinding
    ) {
        activityBinding = binding
        activity = binding.activity
        binding.addRequestPermissionsResultListener(permissionResultListener)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeRequestPermissionsResultListener(
            permissionResultListener
        )
        activityBinding = null
        activity = null
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(
            permissionResultListener
        )
        activityBinding = null
        activity = null
    }

    // ------------------------------------------------------------------ //
    // MethodChannel.MethodCallHandler                                     //
    // ------------------------------------------------------------------ //

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasPermission" -> result.success(hasReadCalendarPermission())
            "requestPermission" -> requestPermission(result)
            "listCalendars" -> listCalendars(result)
            "listInstances" -> {
                val from = call.argument<Number>("fromMillis")?.toLong()
                val to = call.argument<Number>("toMillis")?.toLong()
                if (from == null || to == null || from < 0 || to < from) {
                    result.error(
                        "bad_args",
                        "fromMillis/toMillis must be millis with 0 <= from <= to",
                        null,
                    )
                } else {
                    listInstances(from, to, result)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun hasReadCalendarPermission(): Boolean {
        val context = applicationContext ?: return false
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.READ_CALENDAR,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (hasReadCalendarPermission()) {
            result.success(true)
            return
        }
        val current = activity
        if (current == null) {
            result.error(
                "no_activity",
                "requestPermission requires an attached Activity",
                null,
            )
            return
        }
        // Exactly one in-flight request; a user can only answer one dialog.
        if (pendingPermissionResult != null) {
            result.error("request_in_flight", "a permission request is pending", null)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            current,
            arrayOf(Manifest.permission.READ_CALENDAR),
            REQUEST_CODE_READ_CALENDAR,
        )
    }

    private fun listCalendars(result: MethodChannel.Result) {
        val context = applicationContext
        if (context == null || executor.isShutdown) {
            result.error("detached", "plugin is detached", null)
            return
        }
        executor.execute {
            val calendars = mutableListOf<Map<String, Any?>>()
            try {
                val projection = arrayOf(
                    CalendarContract.Calendars._ID,
                    CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
                    CalendarContract.Calendars.ACCOUNT_NAME,
                    CalendarContract.Calendars.VISIBLE,
                )
                // Only visible calendars feed the agenda.
                val selection = "${CalendarContract.Calendars.VISIBLE} = 1"
                context.contentResolver.query(
                    CalendarContract.Calendars.CONTENT_URI,
                    projection,
                    selection,
                    null,
                    null,
                )?.use { cursor ->
                    val idCol = cursor.getColumnIndexOrThrow(
                        CalendarContract.Calendars._ID
                    )
                    val displayCol = cursor.getColumnIndexOrThrow(
                        CalendarContract.Calendars.CALENDAR_DISPLAY_NAME
                    )
                    val accountCol = cursor.getColumnIndexOrThrow(
                        CalendarContract.Calendars.ACCOUNT_NAME
                    )
                    val visibleCol = cursor.getColumnIndexOrThrow(
                        CalendarContract.Calendars.VISIBLE
                    )
                    while (cursor.moveToNext()) {
                        calendars.add(
                            mapOf(
                                "id" to cursor.getLong(idCol),
                                "displayName" to cursor.getString(displayCol),
                                "accountName" to cursor.getString(accountCol),
                                "visible" to cursor.getInt(visibleCol),
                            )
                        )
                    }
                }
                postSuccess(result, calendars)
            } catch (e: SecurityException) {
                postError(
                    result,
                    "permission_denied",
                    "READ_CALENDAR is not granted",
                    null,
                )
            } catch (e: Exception) {
                postError(result, "query_failed", e.toString(), null)
            }
        }
    }

    private fun listInstances(
        fromMillis: Long,
        toMillis: Long,
        result: MethodChannel.Result,
    ) {
        val context = applicationContext
        if (context == null || executor.isShutdown) {
            result.error("detached", "plugin is detached", null)
            return
        }
        executor.execute {
            val instances = mutableListOf<Map<String, Any?>>()
            try {
                // CalendarContract.Instances is the Events x Calendars join with
                // recurrences pre-expanded; the range is the pair of appended
                // millis. It carries the calendar columns directly
                // (CALENDAR_DISPLAY_NAME / VISIBLE); ACCOUNT_NAME is not part
                // of the Instances contract, so the equivalent Calendars
                // column constant is used - the provider emits the same
                // "account_name" column for instance rows, so no separate
                // Calendars query is needed.
                val uri = ContentUris.appendId(
                    ContentUris.appendId(
                        CalendarContract.Instances.CONTENT_URI.buildUpon(),
                        fromMillis,
                    ),
                    toMillis,
                ).build()
                val projection = arrayOf(
                    CalendarContract.Instances.EVENT_ID,
                    CalendarContract.Instances.CALENDAR_ID,
                    CalendarContract.Instances.TITLE,
                    CalendarContract.Instances.BEGIN,
                    CalendarContract.Instances.END,
                    CalendarContract.Instances.ALL_DAY,
                    CalendarContract.Instances.EVENT_LOCATION,
                    CalendarContract.Instances.ORGANIZER,
                    CalendarContract.Instances.ACCESS_LEVEL,
                    CalendarContract.Instances.CALENDAR_DISPLAY_NAME,
                    CalendarContract.Calendars.ACCOUNT_NAME,
                    CalendarContract.Instances.VISIBLE,
                )
                val selection = "${CalendarContract.Instances.VISIBLE} = 1"
                val sortOrder = "${CalendarContract.Instances.BEGIN} ASC"
                context.contentResolver.query(
                    uri,
                    projection,
                    selection,
                    null,
                    sortOrder,
                )?.use { cursor ->
                    val eventIdCol = cursor.getColumnIndexOrThrow(
                        CalendarContract.Instances.EVENT_ID
                    )
                    val calendarIdCol = cursor.getColumnIndexOrThrow(
                        CalendarContract.Instances.CALENDAR_ID
                    )
                    val titleCol = cursor.getColumnIndexOrThrow(
                        CalendarContract.Instances.TITLE
                    )
                    val beginCol = cursor.getColumnIndexOrThrow(
                        CalendarContract.Instances.BEGIN
                    )
                    val endCol = cursor.getColumnIndexOrThrow(
                        CalendarContract.Instances.END
                    )
                    val allDayCol = cursor.getColumnIndexOrThrow(
                        CalendarContract.Instances.ALL_DAY
                    )
                    val locationCol = cursor.getColumnIndexOrThrow(
                        CalendarContract.Instances.EVENT_LOCATION
                    )
                    val organizerCol = cursor.getColumnIndexOrThrow(
                        CalendarContract.Instances.ORGANIZER
                    )
                    val accessCol = cursor.getColumnIndexOrThrow(
                        CalendarContract.Instances.ACCESS_LEVEL
                    )
                    val displayNameCol = cursor.getColumnIndexOrThrow(
                        CalendarContract.Instances.CALENDAR_DISPLAY_NAME
                    )
                    val accountCol = cursor.getColumnIndexOrThrow(
                        CalendarContract.Calendars.ACCOUNT_NAME
                    )
                    while (cursor.moveToNext()) {
                        instances.add(
                            mapOf(
                                "eventId" to cursor.getLong(eventIdCol),
                                "calendarId" to cursor.getLong(calendarIdCol),
                                "title" to cursor.getString(titleCol),
                                "beginMillis" to cursor.getLong(beginCol),
                                "endMillis" to cursor.getLong(endCol),
                                "allDay" to cursor.getInt(allDayCol),
                                "location" to cursor.getString(locationCol),
                                "organizer" to cursor.getString(organizerCol),
                                "accessLevel" to cursor.getInt(accessCol),
                                "calendarName" to cursor.getString(displayNameCol),
                                "accountName" to cursor.getString(accountCol),
                            )
                        )
                    }
                }
                postSuccess(result, instances)
            } catch (e: SecurityException) {
                postError(
                    result,
                    "permission_denied",
                    "READ_CALENDAR is not granted",
                    null,
                )
            } catch (e: Exception) {
                postError(result, "query_failed", e.toString(), null)
            }
        }
    }

    private fun postSuccess(result: MethodChannel.Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    private fun postError(
        result: MethodChannel.Result,
        code: String,
        message: String,
        details: Any?,
    ) {
        mainHandler.post { result.error(code, message, details) }
    }
}
