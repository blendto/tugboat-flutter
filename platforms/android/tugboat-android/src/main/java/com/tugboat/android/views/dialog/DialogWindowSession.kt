package com.tugboat.android.views.dialog

import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewTreeObserver
import android.view.Window
import com.tugboat.android.views.AdapterGuard
import com.tugboat.android.views.callback.WindowCallbackInstaller
import com.tugboat.android.views.callback.WindowEventObserver
import com.tugboat.android.views.facts.FactClock
import com.tugboat.android.views.facts.ViewsFact
import com.tugboat.android.views.identity.AnchorResolver
import com.tugboat.android.views.identity.TapEvidence
import com.tugboat.android.views.input.FocusFactProducer
import com.tugboat.android.views.input.FocusState
import com.tugboat.android.views.input.GestureConfig
import com.tugboat.android.views.input.PointerFactProducer
import com.tugboat.android.views.input.SurfaceOffset
import com.tugboat.android.views.input.SystemInputProducer
import com.tugboat.android.views.region.Regions
import java.lang.ref.WeakReference

/** What a dialog window session shares with its activity's session. */
internal class DialogSessionContext(
    val clock: FactClock,
    val gesture: GestureConfig,
    val anchors: AnchorResolver,
    val focusState: FocusState,
    /** The activity's decor view: the surface pointer positions are reported in. */
    val surface: () -> View?,
    val density: () -> Float,
    val emit: (ViewsFact) -> Unit,
    val requestFrame: () -> Unit,
    /** `View::getLocationOnScreen`; a seam for tests (Robolectric puts every window at 0,0). */
    val locateOnScreen: (View, IntArray) -> Unit,
)

/**
 * The adapter on one dialog window of an activity: `input.pointer` (with tap
 * evidence), `systemInput`, and `focus` facts, from the same producers as
 * the activity window's session. No scroll facts and no pixels (the
 * activity frame keeps `overlayWindow`).
 *
 * - **Coordinates.** Pointer positions are reported in the activity
 *   decor's space (the surface), moved by the dialog decor's on-screen
 *   offset from it ([SurfaceOffset]); taps are hit-tested in the dialog
 *   window's own space against its decor. Anchors resolve under the
 *   activity's route with paths rooted at the dialog's content (or its
 *   `DialogFragment`'s view), and `relativePosition` is relative to the
 *   dialog decor.
 * - **Focus.** Window focus is app-wide ([FocusState]): the dialog window
 *   becomes the active one when it gains window focus, and the activity's
 *   takes over again when the activity window regains it.
 * - **Lifecycle.** [attach] wraps the dialog window's callback and hooks
 *   its decor; [detach] (window detached, dialog fragment stopped, the
 *   activity session detached) removes both, unwrapping only when
 *   Tugboat's wrapper is on top. Detached, it emits nothing, even if its
 *   wrapper has to stay below a foreign one. It holds the window and decor
 *   weakly, so a missed detach never keeps a dialog alive. A wrapper left
 *   below a foreign one keeps this session, and through [context]'s
 *   closures its activity's window session, reachable from the `Dialog`
 *   (which already holds the activity, so no new leak class).
 *
 * Main thread only.
 */
internal class DialogWindowSession(
    window: Window,
    decor: View,
    private val context: DialogSessionContext,
    private val onWindowDetached: (DialogWindowSession) -> Unit,
) : WindowEventObserver {
    private val windowRef = WeakReference(window)
    private val decorRef = WeakReference(decor)
    private var attached = false
    private val pointers = PointerFactProducer(
        context.clock,
        context.gesture,
        context.density,
        ::resolveTap,
        ::emitIfAttached,
        ::surfaceOffset,
    )
    private val keys = SystemInputProducer(context.clock, ::emitIfAttached)
    private val focus = FocusFactProducer(context.clock, ::emitIfAttached, context.requestFrame, context.focusState)
    private val attachListener = object : ViewTreeObserver.OnWindowAttachListener {
        override fun onWindowAttached() = Unit

        override fun onWindowDetached() =
            AdapterGuard.run("dialog window detached") { onWindowDetached(this@DialogWindowSession) }
    }

    val decor: View?
        get() = decorRef.get()

    val isAttached: Boolean
        get() = attached

    fun attach() {
        if (attached) return
        val window = windowRef.get() ?: return
        val view = decorRef.get() ?: return
        attached = true
        WindowCallbackInstaller.ensureInstalled(window, this)
        view.viewTreeObserver.apply {
            addOnGlobalFocusChangeListener(focus)
            addOnWindowAttachListener(attachListener)
        }
        // Focus may have reached the dialog before it was found.
        if (view.hasWindowFocus()) focus.activate()
        context.requestFrame()
    }

    fun detach() {
        if (!attached) return
        attached = false
        focus.deactivate()
        decorRef.get()?.viewTreeObserver?.takeIf { it.isAlive }?.apply {
            removeOnGlobalFocusChangeListener(focus)
            removeOnWindowAttachListener(attachListener)
        }
        windowRef.get()?.let(WindowCallbackInstaller::uninstall)
    }

    fun onFrame() {
        if (!attached) return
        if (focus.onFrame(decorRef.get()?.findFocus())) context.requestFrame()
    }

    override fun onTouch(event: MotionEvent) {
        if (!attached) return
        pointers.onTouch(event)
        if (event.actionMasked == MotionEvent.ACTION_UP) inputHappened()
    }

    override fun onKey(event: KeyEvent) {
        if (!attached) return
        keys.onKey(event)
        inputHappened()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        if (attached && hasFocus) focus.activate()
    }

    /** Region focus can move without a View focus change: re-read it on the next frames. */
    private fun inputHappened() {
        if (!Regions.any) return
        focus.onInput()
        context.requestFrame()
    }

    private fun resolveTap(x: Float, y: Float): TapEvidence {
        val view = decorRef.get() ?: return TapEvidence.failed(TapEvidence.NO_TARGET_AT_POINT)
        return context.anchors.tapEvidence(view, x, y)
    }

    private fun surfaceOffset(): SurfaceOffset {
        val view = decorRef.get() ?: return SurfaceOffset.ZERO
        return SurfaceOffset.of(view, context.surface(), context.locateOnScreen)
    }

    private fun emitIfAttached(fact: ViewsFact) {
        if (attached) context.emit(fact)
    }
}
