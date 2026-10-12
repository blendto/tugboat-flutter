package com.tugboat.android.views.scroll

import android.view.View
import androidx.recyclerview.widget.RecyclerView
import com.tugboat.android.views.AdapterGuard
import com.tugboat.android.views.OptionalAndroidx
import com.tugboat.android.views.facts.FactClock
import com.tugboat.android.views.facts.ViewsFact
import com.tugboat.android.views.identity.TargetAnchor
import java.util.WeakHashMap

/**
 * Scroll facts for `RecyclerView`s through `addOnScrollListener` (which
 * chains with the app's listeners). Created only when
 * [OptionalAndroidx.recyclerView] is true.
 *
 * - `DRAGGING` or `SETTLING` from idle sends `start` with the list's anchor.
 * - `onScrolled` sends `update`; a scroll while idle (`scrollBy`,
 *   `scrollToPosition`) sends `start` (at the offset before it), `update`,
 *   and `end` at once.
 * - Back to `IDLE` sends `end`. A drag that moved nothing while the list
 *   cannot scroll further one way sends `overscroll` first.
 *
 * Main thread only.
 */
internal class RecyclerScrollTracker(
    private val clock: FactClock,
    private val anchorFor: (View) -> TargetAnchor?,
    private val emit: (ViewsFact) -> Unit,
) {
    private val listeners = WeakHashMap<RecyclerView, Listener>()

    fun track(view: View) {
        val list = view as? RecyclerView ?: return
        if (listeners.containsKey(list)) return
        val listener = Listener()
        listeners[list] = listener
        list.addOnScrollListener(listener)
    }

    fun detachAll() {
        listeners.forEach { (list, listener) -> list.removeOnScrollListener(listener) }
        listeners.clear()
    }

    private inner class Listener : RecyclerView.OnScrollListener() {
        private var active = false
        private var moved = false

        override fun onScrollStateChanged(list: RecyclerView, newState: Int) =
            AdapterGuard.run("recycler scroll state") {
                when {
                    newState != RecyclerView.SCROLL_STATE_IDLE && !active -> start(list)
                    newState == RecyclerView.SCROLL_STATE_IDLE && active -> finish(list)
                }
            }

        override fun onScrolled(list: RecyclerView, dx: Int, dy: Int) =
            AdapterGuard.run("recycler scrolled") {
                if (dx == 0 && dy == 0) return@run
                val idle = list.scrollState == RecyclerView.SCROLL_STATE_IDLE
                if (!active) start(list, restingDelta = dx + dy)
                moved = true
                send(list, ScrollPhase.Update)
                if (idle) finish(list)
            }

        /** [restingDelta] is the movement already applied when the start is noticed late (in `onScrolled`). */
        private fun start(list: RecyclerView, restingDelta: Int = 0) {
            active = true
            moved = false
            send(list, ScrollPhase.Start, anchorFor(list), restingDelta)
        }

        private fun finish(list: RecyclerView) {
            if (!moved && atAnEdge(list)) send(list, ScrollPhase.Overscroll)
            active = false
            send(list, ScrollPhase.End)
        }

        private fun send(list: RecyclerView, phase: ScrollPhase, anchor: TargetAnchor? = null, restingDelta: Int = 0) {
            val current = Scrollables.metrics(list) ?: return
            val metrics = current.copy(offsetPx = current.offsetPx - restingDelta)
            val density = list.resources.displayMetrics.density
            emit(ScrollFacts.fact(ScrollableIds.of(list), phase, metrics, density, clock.now(), anchor))
        }

        private fun atAnEdge(list: RecyclerView): Boolean =
            if (Scrollables.metrics(list)?.axis == ScrollAxis.Horizontal) {
                !list.canScrollHorizontally(-1) || !list.canScrollHorizontally(1)
            } else {
                !list.canScrollVertically(-1) || !list.canScrollVertically(1)
            }
    }
}
