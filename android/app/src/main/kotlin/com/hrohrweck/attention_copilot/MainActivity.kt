package com.hrohrweck.attention_copilot

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // App-code plugin (not a pub plugin): registered here, needs the Activity for runtime permissions.
        flutterEngine.plugins.add(CalendarPlugin())
    }
}
