package com.hrohrweck.attention_copilot

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Re-arm hook after a device reboot.
 *
 * Android discards every scheduled alarm on reboot; a meeting alert must not
 * silently disappear with them. This receiver sets a persisted flag that the
 * Dart side consumes on the next app start, triggering the reschedule path
 * (`AndroidResilience.rescheduleOnBoot`), which re-plans every pending
 * trigger from its persisted absolute instant rather than trusting the OS
 * alarm cache.
 *
 * The receiver deliberately does NOT start the app: on Android 15+ launching
 * activities or foreground services from BOOT_COMPLETED receivers is
 * restricted, and opening the UI after every reboot would be hostile. The
 * flag is durable — the reschedule runs on the next launch, before the first
 * agenda plan, and the normal app-start restore path re-arms the earliest
 * pending trigger regardless of this flag.
 *
 * The flag is written to the file the `shared_preferences` Dart plugin reads
 * (`FlutterSharedPreferences`, keys prefixed `flutter.`) so the Dart side
 * needs no extra plugin or channel: `SharedPreferencesBootRescheduleFlag`
 * reads `boot_reschedule_pending` directly.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        try {
            context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(FLAG_KEY, true)
                .apply()
        } catch (_: Exception) {
            // Never crash the boot broadcast. If this write fails, the
            // regular app-start restore path still re-arms the earliest
            // pending trigger from its persisted absolute instant.
        }
    }

    companion object {
        /** The backing file `shared_preferences` reads on Android. */
        const val PREFS_FILE = "FlutterSharedPreferences"

        /** The `flutter.`-prefixed key `shared_preferences` maps to `boot_reschedule_pending`. */
        const val FLAG_KEY = "flutter.boot_reschedule_pending"
    }
}
