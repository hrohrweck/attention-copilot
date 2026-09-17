package com.hrohrweck.attention_copilot

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The alarm notification's full-screen intent targets the launcher
        // activity (flutter_local_notifications behaviour). When we arrive
        // here through that path, show over the lock screen and hand off to
        // the dedicated ringing activity so the alarm is visible even when
        // the device is locked.
        if (isAlertLaunch(intent)) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            routeToAlertActivity(intent)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // App-code plugin (not a pub plugin): registered here, needs the Activity for runtime permissions.
        flutterEngine.plugins.add(CalendarPlugin())
    }

    /**
     * Whether this launch is the alarm notification being tapped/full-screen
     * launched: the plugin's SELECT_NOTIFICATION action carrying the alarm
     * payload.
     */
    private fun isAlertLaunch(intent: Intent?): Boolean =
        intent != null &&
            intent.action == "SELECT_NOTIFICATION" &&
            !intent.getStringExtra("payload").isNullOrEmpty()

    /** Forwards the alarm notification launch to the ringing activity. */
    private fun routeToAlertActivity(launchIntent: Intent) {
        val alert = Intent(this, AlertActivity::class.java)
            .putExtra(
                AlertActivity.EXTRA_PAYLOAD,
                launchIntent.getStringExtra("payload"),
            )
            .putExtra(
                AlertActivity.EXTRA_NOTIFICATION_ID,
                launchIntent.getIntExtra("notificationId", 0),
            )
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        startActivity(alert)
    }
}
