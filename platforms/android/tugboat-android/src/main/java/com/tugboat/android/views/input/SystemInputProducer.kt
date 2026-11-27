package com.tugboat.android.views.input

import android.view.KeyEvent
import com.tugboat.android.views.facts.FactClock
import com.tugboat.android.views.facts.FactTypes
import com.tugboat.android.views.facts.ViewsFact
import org.json.JSONObject

/**
 * `systemInput {input}` facts from allowlisted keys seen by the window's
 * `dispatchKeyEvent`: the first key-down only (no repeats, no ups). The key
 * still goes to the app unchanged.
 *
 * Known gap: with predictive back (`OnBackInvokedCallback`, API 33+ when
 * the app opts in), back never reaches `dispatchKeyEvent`, and observing it
 * would mean consuming it. `POWER` is in the allowlist for parity but the
 * system rarely delivers it to apps.
 */
internal class SystemInputProducer(
    private val clock: FactClock,
    private val emit: (ViewsFact) -> Unit,
) {
    fun onKey(event: KeyEvent) {
        if (event.action != KeyEvent.ACTION_DOWN || event.repeatCount != 0) return
        val input = ALLOWLIST[event.keyCode] ?: return
        emit(ViewsFact(FactTypes.SYSTEM_INPUT, JSONObject().put("input", input), clock.at(event)))
    }

    private companion object {
        val ALLOWLIST = mapOf(
            KeyEvent.KEYCODE_BACK to "back",
            KeyEvent.KEYCODE_VOLUME_UP to "volume_up",
            KeyEvent.KEYCODE_VOLUME_DOWN to "volume_down",
            KeyEvent.KEYCODE_VOLUME_MUTE to "volume_mute",
            KeyEvent.KEYCODE_POWER to "power",
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE to "media_play_pause",
        )
    }
}
