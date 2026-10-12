package com.tugboat.android.views.input

import android.view.View
import android.view.ViewTreeObserver
import com.tugboat.android.toolkit.RegionFocus
import com.tugboat.android.views.AdapterGuard
import com.tugboat.android.views.facts.FactClock
import com.tugboat.android.views.facts.FactTypes
import com.tugboat.android.views.facts.ViewsFact
import com.tugboat.android.views.identity.ViewRules
import com.tugboat.android.views.region.Regions
import org.json.JSONObject

/**
 * `focus {kind}` facts from a window's `OnGlobalFocusChangeListener`:
 * `text_input` when an editable `TextView` (`EditText` and subclasses) takes
 * focus, `none` when focus leaves the window's views, `other` otherwise.
 * Consecutive equal kinds are sent once. The engine records only
 * transitions that involve a text input.
 *
 * A toolkit region host (Compose) moves focus inside itself without a View
 * focus change, so when it holds View focus its region reports the kind, and
 * [onFrame] re-reads it for [RECHECK_FRAMES] frames after each input event
 * ([onInput]).
 */
internal class FocusFactProducer(
    private val clock: FactClock,
    private val emit: (ViewsFact) -> Unit,
) : ViewTreeObserver.OnGlobalFocusChangeListener {
    private var lastKind: String? = null
    private var recheckFrames = 0

    override fun onGlobalFocusChanged(oldFocus: View?, newFocus: View?) =
        AdapterGuard.run("focus change") { report(newFocus) }

    /** An input event happened: region focus may move on the next frames. */
    fun onInput() {
        recheckFrames = RECHECK_FRAMES
    }

    /** Re-reads region focus while a recheck is pending; true when another frame is wanted. */
    fun onFrame(focused: View?): Boolean {
        if (recheckFrames <= 0) return false
        recheckFrames--
        if (focused != null && Regions.hostOf(focused) != null) report(focused)
        return recheckFrames > 0
    }

    private fun report(focused: View?) {
        val kind = kindOf(focused)
        if (kind == lastKind) return
        lastKind = kind
        emit(ViewsFact(FactTypes.FOCUS, JSONObject().put("kind", kind), clock.now()))
    }

    private fun kindOf(view: View?): String =
        when {
            view == null -> "none"
            ViewRules.isEditable(view) -> TEXT_INPUT
            Regions.hostOf(view)?.focus() == RegionFocus.TextInput -> TEXT_INPUT
            else -> "other"
        }

    private companion object {
        const val TEXT_INPUT = "text_input"

        /** Compose applies focus and its semantics within a frame or two of the input event. */
        const val RECHECK_FRAMES = 4
    }
}
