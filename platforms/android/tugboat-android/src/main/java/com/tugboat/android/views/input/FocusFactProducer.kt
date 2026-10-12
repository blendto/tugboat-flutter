package com.tugboat.android.views.input

import android.view.View
import android.view.ViewTreeObserver
import com.tugboat.android.host.HostTime
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
 * **Settled, once per frame.** A View focus change is not reported at once:
 * it is evaluated on the next frame ([onFrame]), stamped with the time of
 * the change, so several changes within a frame report only where focus
 * settled. A toolkit region host (Compose) gains View focus a frame or two
 * before its own focus settles inside it, so while it does not yet report
 * a text input the evaluation waits up to [RECHECK_FRAMES] frames: one tap
 * on a Compose text field is one `text_input`, not `other` then
 * `text_input`.
 *
 * Region focus also moves without a View focus change, so [onFrame] re-reads
 * it for [RECHECK_FRAMES] frames after each input event ([onInput]).
 *
 * **One focus across windows.** Focus is app-wide, as Dart's
 * `FocusManager` is: [state] (the last reported kind) is shared by every
 * window's producer, and a window that becomes active ([onWindowActive])
 * is evaluated like a focus change. Navigating from a focused field to
 * another activity therefore reports that activity's kind (`none` or
 * `other`), and coming back reports `text_input` again.
 */
internal class FocusFactProducer(
    private val clock: FactClock,
    private val emit: (ViewsFact) -> Unit,
    private val requestFrame: () -> Unit = {},
    private val state: FocusState = FocusState(),
) : ViewTreeObserver.OnGlobalFocusChangeListener {
    private var recheckFrames = 0

    /** When the View focus changed, until that change is reported. */
    private var changedAt: HostTime? = null

    override fun onGlobalFocusChanged(oldFocus: View?, newFocus: View?) =
        AdapterGuard.run("focus change") {
            if (changedAt == null) changedAt = clock.now()
            recheckFrames = RECHECK_FRAMES
            requestFrame()
        }

    /** This window became the active one: its focus is the app's focus now. */
    fun onWindowActive() = onGlobalFocusChanged(null, null)

    /** An input event happened: region focus may move on the next frames. */
    fun onInput() {
        recheckFrames = RECHECK_FRAMES
    }

    /** Evaluates focus for this frame ([focused] is the window's focused view); true when another frame is wanted. */
    fun onFrame(focused: View?): Boolean {
        val change = changedAt
        if (change == null && recheckFrames <= 0) return false
        if (recheckFrames > 0) recheckFrames--
        val kind = kindOf(focused)
        val inRegion = focused != null && Regions.hostOf(focused) != null
        when {
            change != null && inRegion && kind != TEXT_INPUT && recheckFrames > 0 -> Unit // region focus may still settle
            change != null -> {
                changedAt = null
                report(kind, change)
            }
            inRegion -> report(kind, clock.now())
        }
        return changedAt != null || recheckFrames > 0
    }

    private fun report(kind: String, at: HostTime) {
        if (kind == state.lastKind) return
        state.lastKind = kind
        emit(ViewsFact(FactTypes.FOCUS, JSONObject().put("kind", kind), at))
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

/** The last focus kind reported, shared by every window's [FocusFactProducer]. Main thread only. */
internal class FocusState {
    var lastKind: String? = null
}
