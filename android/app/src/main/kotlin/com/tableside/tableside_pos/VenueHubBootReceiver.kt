package com.tableside.tableside_pos

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class VenueHubBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (!VenueHubForegroundService.wasEnabled(context)) return
        // Android cannot safely recreate the encrypted Dart hub in a bare boot
        // receiver. Keep the process available and ask the operator to reopen
        // TableSide; the Flutter runtime then marks the service genuinely ready.
        VenueHubForegroundService.start(context, runtimeReady = false)
    }
}
