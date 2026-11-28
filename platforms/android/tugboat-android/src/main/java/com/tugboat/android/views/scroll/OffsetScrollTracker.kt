package com.tugboat.android.views.scroll

import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.ViewTreeObserver
import com.tugboat.android.host.HostTime
import com.tugboat.android.views.AdapterGuard
import com.tugboat.android.views.OptionalAndroidx
import com.tugboat.android.views.facts.FactClock
import com.tugboat.android.views.facts.ViewsFact
import com.tugboat.android.views.identity.HitTester
import com.tugboat.android.views.identity.TargetAnchor
import com.tugboat.android.views.identity.ViewGeometry
import com.tugboat.android.views.identity.ViewRules
import java.util.WeakHashMap
import kotlin.math.abs

/**
 * Scroll facts for one window's scrollables other than `RecyclerView`
 * ([RecyclerScrollTracker] owns those), by comparing offsets.
 *
 * - `OnScrollChangedListener` marks the window dirty; on the next frame
 *   ([onFrame]) every known scrollable's offset is compared with the last
 *   one seen. A first change sends `start` (at the resting offset, with the
 *   scrollable's anchor), then `update`; [idleMs] without a change sends
 *   `end`.
 * - A finger down ([onTouch]) registers the scrollables under it that discovery
 *   has not seen yet (a list mounted without a layout pass, as React Native does).
 * - A finger lift ([onTouch]) also diffs the offsets at once, so a drag that
 *   moved a scrollable has its `start` before the pointer is released (the
 *   engine links a scroll to the pointer still pending; a quick flick can lift
 *   before the next frame, and was recorded as a target-less swipe).
 * - Scrollables are discovered on the first frame and after layout passes
 *   (at most every 200 ms), and their offsets are the baseline: a scrollable never seen at rest
 *   sends nothing until it moves again. Discovered `RecyclerView`s go to
 *   [onRecyclerView].
 * - Overscroll comes from the window's touches ([onTouch], which never
 *   consumes them), by the rule [RecyclerScrollTracker] uses (Flutter counts
 *   every `OverscrollNotification`, so it can count more than one per drag): a
 *   drag past the touch slop that moved no scrollable, on a scrollable that
 *   cannot scroll further in the drag's direction, sends `start`,
 *   `overscroll`, `end` once, when the finger lifts. The scrollable is the
 *   nearest one under the touch that scrolls on the drag's axis; a
 *   `RecyclerView` is left to its own tracker, and one that cannot scroll
 *   (its content fits) is skipped for the one above it. Known gaps: it is
 *   not seen whether the scrollable took the drag, so a child that consumes
 *   drags without scrolling (a signature pad, a map, a Compose list, a
 *   collapsing app bar, a list with scrolling turned off) inside a
 *   scrollable at its edge also reports one; slop and axis use the net
 *   displacement from down to up, so a pull that returns to its start is
 *   missed; any scroll in the window during the drag suppresses it; and
 *   `onScrollChanged` runs at the next draw, so a scroll in the same input
 *   batch as the lift can be missed, and then both a scroll and an
 *   overscroll are reported.
 *
 * Main thread only.
 */
internal class OffsetScrollTracker(
    private val root: View,
    private val clock: FactClock,
    private val anchorFor: (View) -> TargetAnchor?,
    private val emit: (ViewsFact) -> Unit,
    private val requestFrame: () -> Unit,
    private val onRecyclerView: (View) -> Unit = {},
    private val idleMs: Long = DEFAULT_IDLE_MS,
) : ViewTreeObserver.OnScrollChangedListener, ViewTreeObserver.OnGlobalLayoutListener {
    private class State(var metrics: ScrollMetrics, var active: Boolean = false, var lastChangeMonoUs: Long = 0)

    private val states = WeakHashMap<View, State>()
    private var dirty = false
    private var needsDiscovery = true
    private var nextDiscoveryMonoUs = Long.MIN_VALUE
    private var gestureOpen = false
    private var movedSinceDown = false
    private var downX = 0f
    private var downY = 0f

    override fun onScrollChanged() = AdapterGuard.run("scroll changed") {
        if (gestureOpen) movedSinceDown = true
        dirty = true
        requestFrame()
    }

    override fun onGlobalLayout() = AdapterGuard.run("scroll layout") {
        needsDiscovery = true
        requestFrame()
    }

    /** Window touches, before dispatch. Only a one-pointer gesture's lift (not a cancel) looks for an overscroll. */
    fun onTouch(event: MotionEvent) {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                gestureOpen = true
                movedSinceDown = false
                downX = event.x
                downY = event.y
                trackUnder(downX, downY)
            }
            MotionEvent.ACTION_POINTER_DOWN -> gestureOpen = false
            MotionEvent.ACTION_UP -> {
                // Offsets are read here, not only on the next frame: a quick drag lifts before the
                // frame that would notice it, and its `start` must exist for the pointer to link to.
                readOffsetsNow()
                if (gestureOpen && !movedSinceDown) overscroll(event.x, event.y)
                gestureOpen = false
            }
            MotionEvent.ACTION_CANCEL -> gestureOpen = false // the system took the gesture
        }
    }

    /**
     * Registers the scrollables under the finger that discovery has not seen, with their resting
     * offset as the baseline. React Native mounts a screen's views without a layout pass (its
     * views ignore `requestLayout`), so [onGlobalLayout] never asks for discovery and a list on a
     * screen opened after the last walk was never tracked.
     */
    private fun trackUnder(x: Float, y: Float) {
        var view = HitTester.hit(root, x, y)
        while (view != null) {
            if (isRecycler(view)) {
                onRecyclerView(view)
            } else if (Scrollables.isScrollable(view) && !states.containsKey(view)) {
                Scrollables.metrics(view)?.let { states[view] = State(it) }
            }
            view = view.parent as? View
        }
    }

    private fun readOffsetsNow() {
        val now = clock.now()
        var changed = false
        for ((view, state) in states.entries.toList()) {
            if (diff(view, state, now)) changed = true
        }
        if (!changed) return
        if (gestureOpen) movedSinceDown = true
        requestFrame() // the idle `end` is sent from a frame
    }

    private fun overscroll(upX: Float, upY: Float) {
        val dx = upX - downX
        val dy = upY - downY
        val slop = ViewConfiguration.get(root.context).scaledTouchSlop
        if (maxOf(abs(dx), abs(dy)) <= slop) return
        val vertical = abs(dy) >= abs(dx)
        val axis = if (vertical) ScrollAxis.Vertical else ScrollAxis.Horizontal
        var view = HitTester.hit(root, downX, downY)
        while (view != null) {
            if (Scrollables.isScrollable(view) && Scrollables.metrics(view)?.axis == axis) {
                if (isRecycler(view)) return
                // Content that fits scrolls neither way: the drag is for a scrollable above it.
                if (canScroll(view, vertical, -1) || canScroll(view, vertical, 1)) break
            }
            view = view.parent as? View
        }
        if (view == null || states[view]?.active == true) return
        // The drag in the scrollable's own coordinates (a flipped list, as an inverted
        // FlatList is, reverses it): down or right pulls the content toward its start.
        val from = ViewGeometry.toDescendant(root, view, downX, downY) ?: return
        val to = ViewGeometry.toDescendant(root, view, upX, upY) ?: return
        val towardStart = (if (vertical) to[1] - from[1] else to[0] - from[0]) > 0
        if (canScroll(view, vertical, if (towardStart) -1 else 1)) return
        val metrics = Scrollables.metrics(view) ?: return
        val id = ScrollableIds.of(view)
        val at = clock.now()
        emit(ScrollFacts.fact(id, ScrollPhase.Start, metrics, density(), at, anchorFor(view)))
        emit(ScrollFacts.fact(id, ScrollPhase.Overscroll, metrics, density(), at))
        emit(ScrollFacts.fact(id, ScrollPhase.End, metrics, density(), at))
    }

    private fun canScroll(view: View, vertical: Boolean, direction: Int): Boolean =
        if (vertical) view.canScrollVertically(direction) else view.canScrollHorizontally(direction)

    /** Diffs offsets and ends idle scrolls. Called once per frame. */
    fun onFrame() {
        val now = clock.now()
        if (needsDiscovery) discover(now.monoUs)
        if (dirty) {
            dirty = false
            states.entries.toList().forEach { (view, state) -> diff(view, state, now) }
        }
        var anyActive = false
        for ((view, state) in states.entries.toList()) {
            if (!state.active) continue
            if (now.monoUs - state.lastChangeMonoUs >= idleMs * MICROS_PER_MILLI) {
                state.active = false
                emit(ScrollFacts.fact(ScrollableIds.of(view), ScrollPhase.End, state.metrics, density(), now))
            } else {
                anyActive = true
            }
        }
        if (anyActive) requestFrame()
    }

    private fun diff(view: View, state: State, at: HostTime): Boolean {
        val metrics = Scrollables.metrics(view) ?: return false
        if (metrics.offsetPx == state.metrics.offsetPx) return false
        val id = ScrollableIds.of(view)
        if (!state.active) {
            state.active = true
            emit(ScrollFacts.fact(id, ScrollPhase.Start, state.metrics, density(), at, anchorFor(view)))
        }
        state.metrics = metrics
        state.lastChangeMonoUs = at.monoUs
        emit(ScrollFacts.fact(id, ScrollPhase.Update, metrics, density(), at))
        return true
    }

    /** Walks the tree at most every [DISCOVERY_INTERVAL_US], so layout animations stay cheap. */
    private fun discover(nowMonoUs: Long) {
        if (nowMonoUs < nextDiscoveryMonoUs) {
            requestFrame()
            return
        }
        needsDiscovery = false
        nextDiscoveryMonoUs = nowMonoUs + DISCOVERY_INTERVAL_US
        walk(root)
    }

    private fun walk(view: View) {
        if (ViewRules.isExcluded(view)) return
        if (isRecycler(view)) {
            onRecyclerView(view)
        } else if (Scrollables.isScrollable(view) && !states.containsKey(view)) {
            Scrollables.metrics(view)?.let { states[view] = State(it) }
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) walk(view.getChildAt(i))
        }
    }

    private fun isRecycler(view: View): Boolean = OptionalAndroidx.recycler.isRecyclerView(view)

    private fun density(): Float = root.resources.displayMetrics.density

    private companion object {
        const val DEFAULT_IDLE_MS = 150L
        const val DISCOVERY_INTERVAL_US = 200_000L
        const val MICROS_PER_MILLI = 1_000L
    }
}
