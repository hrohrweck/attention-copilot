package com.hrohrweck.attention_copilot

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

/**
 * Full-screen ringing surface for meeting alerts.
 *
 * Launched when an alarm notification fires (the full-screen intent lands on
 * [MainActivity], which routes here). Declared in the manifest with
 * `android:showWhenLocked="true"` and `android:turnScreenOn="true"`; the
 * programmatic calls below are the runtime equivalent and also keep the
 * screen on while the alert is ringing.
 *
 * The alert only stops on explicit acknowledgement (todo 19 binds the UI to
 * the engine); the back button / swipe-away must not dismiss it.
 */
class AlertActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Show over the lock screen and wake the device: an alarm that cannot
        // be seen is not an alarm.
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        // Keep the screen on while the alert rings; released on acknowledgement
        // (the activity finishes).
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // Payload routing for the ringing UI (todo 19): the alarm id / payload
        // arrives via the full-screen-intent launch path in MainActivity.
        alertPayload = intent?.getStringExtra(EXTRA_PAYLOAD)
        alertNotificationId = intent?.getIntExtra(EXTRA_NOTIFICATION_ID, 0) ?: 0
    }

    companion object {
        /** Extra carrying the engine alarm id (notification payload). */
        const val EXTRA_PAYLOAD = "payload"

        /** Extra carrying the alarm notification id. */
        const val EXTRA_NOTIFICATION_ID = "notificationId"

        /**
         * The alarm payload of the alert currently ringing, if any. Read by
         * the Dart side to know which alert this activity is ringing for.
         * Replaced by proper intent handling in todo 19.
         */
        var alertPayload: String? = null
            private set

        /** The notification id of the alert currently ringing, if any. */
        var alertNotificationId: Int = 0
            private set
    }
}
