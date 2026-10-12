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
import com.tugboat.android.views.input.GestureConfig
import com.tugboat.android.views.input.PointerFactProducer
import com.tugboat.android.views.input.SystemInputProducer
import com.tugboat.android.views.scroll.OffsetScrollTracker
import com.tugboat.android.views.scroll.RecyclerScrollTracker

/**
 * Everything the adapter attaches to one activity window: the window
 * callback (pointer and key facts), and the decor view's focus, scroll, and
 * layout listeners. Main thread only. After [detach] it emits nothing, even
 * if its window callback has to stay in a foreign wrapper's chain.
 */
internal class WindowSession(
    private val activity: Activity,
    private val clock: FactClock,
    gesture: GestureConfig,
    private val anchors: AnchorResolver,
    private val emit: (ViewsFact) -> Unit,
    private val requestFrame: () -> Unit,
) : WindowEventObserver {
    private var attached = true
    private var decor: View? = null
    private val pointers = PointerFactProducer(clock, gesture, ::density, ::resolveTap, ::emitIfAttached)
    private val keys = SystemInputProducer(clock, ::emitIfAttached)
    private val focus = FocusFactProducer(clock, ::emitIfAttached)
    private val recyclers =
        if (OptionalAndroidx.hasRecyclerView) RecyclerScrollTracker(clock, anchors::anchorFor, ::emitIfAttached) else null
    private var scrolls: OffsetScrollTracker? = null

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
        view.viewTreeObserver.apply {
            addOnGlobalFocusChangeListener(focus)
            addOnScrollChangedListener(tracker)
            addOnGlobalLayoutListener(tracker)
        }
        requestFrame()
    }

    fun onFrame() {
        if (attached) scrolls?.onFrame()
    }

    fun detach() {
        if (!attached) return
        attached = false
        unhookDecor()
        recyclers?.detachAll()
        activity.window?.let(WindowCallbackInstaller::uninstall)
    }

    override fun onTouch(event: MotionEvent) {
        if (attached) pointers.onTouch(event)
    }

    override fun onKey(event: KeyEvent) {
        if (attached) keys.onKey(event)
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
