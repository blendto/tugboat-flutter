package com.tugboat.sample

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.tugboat.android.Tugboat

/**
 * Debug builds only: drives the activation lifecycle from device scripts.
 *
 * ```sh
 * adb shell am broadcast -n com.tugboat.sample/.TugboatDebugReceiver -a com.tugboat.sample.ACTIVATE --es id run-1
 * adb shell am broadcast -n com.tugboat.sample/.TugboatDebugReceiver -a com.tugboat.sample.DEACTIVATE
 * ```
 */
class TugboatDebugReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_ACTIVATE -> Tugboat.activate(intent.getStringExtra(EXTRA_ID).orEmpty())
            ACTION_DEACTIVATE -> Tugboat.deactivate()
        }
    }

    private companion object {
        const val ACTION_ACTIVATE = "com.tugboat.sample.ACTIVATE"
        const val ACTION_DEACTIVATE = "com.tugboat.sample.DEACTIVATE"
        const val EXTRA_ID = "id"
    }
}
