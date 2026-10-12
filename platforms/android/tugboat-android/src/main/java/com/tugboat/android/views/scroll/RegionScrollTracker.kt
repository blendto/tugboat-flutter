package com.tugboat.android.views.scroll

import android.view.MotionEvent
import android.view.View
import com.tugboat.android.host.HostTime
import com.tugboat.android.toolkit.RegionHit
import com.tugboat.android.toolkit.RegionScrollable
import com.tugboat.android.views.AdapterGuard
import com.tugboat.android.views.facts.FactClock
import com.tugboat.android.views.facts.ViewsFact
import com.tugboat.android.views.identity.HitTester
import com.tugboat.android.views.identity.TargetAnchor
import com.tugboat.android.views.identity.ViewGeometry
import com.tugboat.android.views.region.RegionHost
import com.tugboat.android.views.region.Regions
import java.util.concurrent.atomic.AtomicLong

/**
 * Scroll facts for scrollables inside toolkit region hosts (Compose), which
 * scroll without any View scroll callback (native SDK note 5).
 *
 * - A gesture's first `down` resolves the scrollables under the touch point
 *   in its region host, once; their readers report live offsets, so no tree
 *   is walked per frame. Their offsets then are the baseline.
 * - While a pointer is down, and for [lingerMs] after the last one lifts
 *   (flings), every frame reads them and diffs each offset with its last
 *   one: a first change sends `start` (at the resting offset, with the
 *   scrollable's anchor), then `update`; [idleMs] without a change sends
 *   `end`.
 * - Offsets are per-frame samples of what the region reports, so they are
 *   approximate (a known gap); scrolls without a touch (wheel, programmatic)
 *   are not seen, and overscroll is not reported.
 *
 * Does nothing when no region is registered. Main thread only.
 */
internal class RegionScrollTracker(
    private val root: View,
    private val clock: FactClock,
    private val anchorFor: (RegionHost, RegionHit.Target) -> TargetAnchor?,
    private val emit: (ViewsFact) -> Unit,
    private val requestFrame: () -> Unit,
    private val idleMs: Long = DEFAULT_IDLE_MS,
    private val lingerMs: Long = DEFAULT_LINGER_MS,
) {
    private class Tracked(
        val host: RegionHost,
        val scrollable: RegionScrollable,
        val id: String,
        var metrics: ScrollMetrics,
        var active: Boolean = false,
        var lastChangeMonoUs: Long = 0,
    )

    private var tracked = HashMap<Pair<View, Int>, Tracked>()
    private var pointersDown = false
    private var watchUntilMonoUs = Long.MIN_VALUE

    fun onTouch(event: MotionEvent) {
        if (!Regions.any && tracked.isEmpty()) return
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                pointersDown = true
                resolveAt(event.x, event.y)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                pointersDown = false
                watchUntilMonoUs = clock.now().monoUs + lingerMs * MICROS_PER_MILLI
            }
            else -> Unit
        }
        if (tracked.isNotEmpty()) requestFrame()
    }

    /** Diffs offsets and ends idle scrolls. Called once per frame. */
    fun onFrame() {
        if (tracked.isEmpty()) return
        val now = clock.now()
        val watching = pointersDown || now.monoUs < watchUntilMonoUs
        if (watching) tracked.values.forEach { diff(it, now) }
        val anyActive = endIdle(now)
        if (watching || anyActive) requestFrame()
    }

    fun detach() {
        tracked = HashMap()
    }

    /** Keeps scrolls still running; replaces the rest with the scrollables under the new touch. */
    private fun resolveAt(x: Float, y: Float) {
        val next = HashMap<Pair<View, Int>, Tracked>()
        tracked.values.filter { it.active }.forEach { next[it.host.view to it.scrollable.key] = it }
        val hit = HitTester.hit(root, x, y)
        val host = hit?.let { Regions.enclosing(it, root) }
        val local = host?.let { ViewGeometry.toDescendant(root, it.view, x, y) }
        if (host != null && local != null) {
            for (scrollable in host.scrollablesAt(local[0], local[1])) {
                val key = host.view to scrollable.key
                if (next.containsKey(key)) continue
                val metrics = read(scrollable) ?: continue
                val id = tracked[key]?.id ?: newId(host)
                next[key] = Tracked(host, scrollable, id, metrics)
            }
        }
        tracked = next
    }

    private fun diff(entry: Tracked, at: HostTime) {
        val metrics = read(entry.scrollable) ?: return
        if (metrics.offsetPx == entry.metrics.offsetPx) return
        if (!entry.active) {
            entry.active = true
            val target = AdapterGuard.run("region scroll target", null) { entry.scrollable.target() }
            val anchor = target?.let { anchorFor(entry.host, it) }
            emit(ScrollFacts.fact(entry.id, ScrollPhase.Start, entry.metrics, density(), at, anchor))
        }
        entry.metrics = metrics
        entry.lastChangeMonoUs = at.monoUs
        emit(ScrollFacts.fact(entry.id, ScrollPhase.Update, metrics, density(), at))
    }

    private fun endIdle(now: HostTime): Boolean {
        var anyActive = false
        for (entry in tracked.values) {
            if (!entry.active) continue
            if (now.monoUs - entry.lastChangeMonoUs >= idleMs * MICROS_PER_MILLI) {
                entry.active = false
                emit(ScrollFacts.fact(entry.id, ScrollPhase.End, entry.metrics, density(), now))
            } else {
                anyActive = true
            }
        }
        return anyActive
    }

    private fun read(scrollable: RegionScrollable): ScrollMetrics? =
        AdapterGuard.run("region scroll offset", null) {
            val axis = if (scrollable.vertical) ScrollAxis.Vertical else ScrollAxis.Horizontal
            ScrollMetrics(axis, scrollable.offsetPx(), scrollable.maxExtentPx())
        }

    private fun newId(host: RegionHost): String = "${host.region.toolkit}-scroll-${nextId.getAndIncrement()}"

    private fun density(): Float = root.resources.displayMetrics.density

    private companion object {
        const val DEFAULT_IDLE_MS = 150L
        const val DEFAULT_LINGER_MS = 1_000L
        const val MICROS_PER_MILLI = 1_000L

        /** Process-wide, so ids stay unique across windows. */
        val nextId = AtomicLong(1)
    }
}
