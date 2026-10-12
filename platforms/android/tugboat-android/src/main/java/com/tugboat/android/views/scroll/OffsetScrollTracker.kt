package com.tugboat.android.views.scroll

import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import com.tugboat.android.host.HostTime
import com.tugboat.android.views.AdapterGuard
import com.tugboat.android.views.OptionalAndroidx
import com.tugboat.android.views.facts.FactClock
import com.tugboat.android.views.facts.ViewsFact
import com.tugboat.android.views.identity.RecyclerSupport
import com.tugboat.android.views.identity.ScrollMetrics
import com.tugboat.android.views.identity.Scrollables
import com.tugboat.android.views.identity.TargetAnchor
import com.tugboat.android.views.identity.ViewRules
import java.util.WeakHashMap

/**
 * Scroll facts for one window's scrollables other than `RecyclerView`
 * ([RecyclerScrollTracker] owns those), by comparing offsets.
 *
 * - `OnScrollChangedListener` marks the window dirty; on the next frame
 *   ([onFrame]) every known scrollable's offset is compared with the last
 *   one seen. A first change sends `start` (at the resting offset, with the
 *   scrollable's anchor), then `update`; [idleMs] without a change sends
 *   `end`.
 * - Scrollables are discovered on the first frame and after layout passes,
 *   and their offsets are the baseline: a scrollable never seen at rest
 *   sends nothing until it moves again. Discovered `RecyclerView`s go to
 *   [onRecyclerView].
 * - Overscroll is not observable here without consuming touches: a known
 *   gap (RecyclerView reports it).
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

    override fun onScrollChanged() = AdapterGuard.run("scroll changed") {
        dirty = true
        requestFrame()
    }

    override fun onGlobalLayout() = AdapterGuard.run("scroll layout") {
        needsDiscovery = true
        requestFrame()
    }

    /** Diffs offsets and ends idle scrolls. Called once per frame. */
    fun onFrame() {
        if (needsDiscovery) discover()
        val now = clock.now()
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

    private fun diff(view: View, state: State, at: HostTime) {
        val metrics = Scrollables.metrics(view) ?: return
        if (metrics.offsetPx == state.metrics.offsetPx) return
        val id = ScrollableIds.of(view)
        if (!state.active) {
            state.active = true
            emit(ScrollFacts.fact(id, ScrollPhase.Start, state.metrics, density(), at, anchorFor(view)))
        }
        state.metrics = metrics
        state.lastChangeMonoUs = at.monoUs
        emit(ScrollFacts.fact(id, ScrollPhase.Update, metrics, density(), at))
    }

    private fun discover() {
        needsDiscovery = false
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

    private fun isRecycler(view: View): Boolean =
        OptionalAndroidx.recyclerView && RecyclerSupport.isRecyclerView(view)

    private fun density(): Float = root.resources.displayMetrics.density

    private companion object {
        const val DEFAULT_IDLE_MS = 150L
        const val MICROS_PER_MILLI = 1_000L
    }
}
