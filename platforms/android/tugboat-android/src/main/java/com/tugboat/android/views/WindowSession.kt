package com.tugboat.android.views

import android.app.Activity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
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
import com.tugboat.android.views.input.SystemInputProducer
import com.tugboat.android.views.region.Regions
import com.tugboat.android.views.scroll.OffsetScrollTracker
import com.tugboat.android.views.scroll.RecyclerScrollTracker
import com.tugboat.android.views.scroll.RegionScrollTracker

/**
 * Everything the adapter attaches to one activity window: the window
 * callback (pointer and key facts), the decor view's focus, scroll, and
 * layout listeners, and the frame-driven scroll and focus reads of toolkit
 * region hosts (Compose). Main thread only. After [detach] it emits
 * nothing, even if its window callback has to stay in a foreign wrapper's
 * chain.
 */
internal class WindowSession(
    private val activity: Activity,
    private val clock: FactClock,
    gesture: GestureConfig,
    private val anchors: AnchorResolver,
    private val emit: (ViewsFact) -> Unit,
    private val requestFrame: () -> Unit,
    focusState: FocusState,
) : WindowEventObserver {
    private var attached = true
    private var decor: View? = null
    private val pointers = PointerFactProducer(clock, gesture, ::density, ::resolveTap, ::emitIfAttached)
    private val keys = SystemInputProducer(clock, ::emitIfAttached)
    private val focus = FocusFactProducer(clock, ::emitIfAttached, requestFrame, focusState)
    private val recyclers =
        if (OptionalAndroidx.hasRecyclerView) RecyclerScrollTracker(clock, anchors::anchorFor, ::emitIfAttached) else null
    private var scrolls: OffsetScrollTracker? = null
    private var regionScrolls: RegionScrollTracker? = null

    /** Wraps the window callback if needed and hooks the decor view once it exists. */
    fun ensureAttached() {
        if (!attached) return
        val window = activity.window ?: return
        WindowCallbackInstaller.ensureInstalled(window, this)
        val view = window.peekDecorView() ?: return
        if (decor === view) return
        unhookDecor()
        decor = view
        val tracker = OffsetScrollTracker(
            root = view,
            clock = clock,
            anchorFor = anchors::anchorFor,
            emit = ::emitIfAttached,
            requestFrame = requestFrame,
            onRecyclerView = { list -> recyclers?.track(list) },
        )
        scrolls = tracker
        regionScrolls = RegionScrollTracker(view, clock, anchors.regions::anchor, ::emitIfAttached, requestFrame)
        view.viewTreeObserver.apply {
            addOnGlobalFocusChangeListener(focus)
            addOnScrollChangedListener(tracker)
            addOnGlobalLayoutListener(tracker)
        }
        requestFrame()
    }

    /** This window became the active one (its activity resumed): report its focus on the next frame. */
    fun onWindowActive() {
        if (attached) focus.activate()
    }

    fun onFrame() {
        if (!attached) return
        scrolls?.onFrame()
        regionScrolls?.onFrame()
        if (focus.onFrame(decor?.findFocus())) requestFrame()
    }

    fun detach() {
        if (!attached) return
        attached = false
        focus.deactivate()
        unhookDecor()
        recyclers?.detachAll()
        activity.window?.let(WindowCallbackInstaller::uninstall)
    }

    override fun onTouch(event: MotionEvent) {
        if (!attached) return
        pointers.onTouch(event)
        regionScrolls?.onTouch(event)
        if (event.actionMasked == MotionEvent.ACTION_UP) inputHappened()
    }

    override fun onKey(event: KeyEvent) {
        if (!attached) return
        keys.onKey(event)
        inputHappened()
    }

    private fun unhookDecor() {
        val view = decor ?: return
        val tracker = scrolls
        val observer = view.viewTreeObserver
        if (observer.isAlive) {
            observer.removeOnGlobalFocusChangeListener(focus)
            tracker?.let {
                observer.removeOnScrollChangedListener(it)
                observer.removeOnGlobalLayoutListener(it)
            }
        }
        decor = null
        scrolls = null
        regionScrolls?.detach()
        regionScrolls = null
    }

    /** Region focus can move without a View focus change: re-read it on the next frames. */
    private fun inputHappened() {
        if (!Regions.any) return
        focus.onInput()
        requestFrame()
    }

    private fun resolveTap(x: Float, y: Float): TapEvidence {
        val view = decor ?: activity.window?.peekDecorView() ?: return TapEvidence.failed(TapEvidence.NO_TARGET_AT_POINT)
        return anchors.tapEvidence(view, x, y)
    }

    private fun density(): Float = activity.resources.displayMetrics.density

    private fun emitIfAttached(fact: ViewsFact) {
        if (attached) emit(fact)
    }
}
