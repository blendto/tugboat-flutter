package com.tugboat.android.views.scroll

import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import com.tugboat.android.host.HostTime
import com.tugboat.android.toolkit.RegionHit
import com.tugboat.android.toolkit.RegionScrollable
import com.tugboat.android.views.AdapterGuard
import com.tugboat.android.views.facts.FactClock
import com.tugboat.android.views.facts.ViewsFact
import com.tugboat.android.views.identity.TargetAnchor
import com.tugboat.android.views.identity.ViewRules
import com.tugboat.android.views.region.RegionHost
import com.tugboat.android.views.region.Regions
import java.util.concurrent.atomic.AtomicLong

/**
 * Scroll facts for scrollables inside toolkit region hosts (Compose), which
 * scroll without any View scroll callback (native SDK note 5).
 *
 * - A gesture's first `down` finds the window's region hosts and samples
 *   their scrollables as the baseline.
 * - While a pointer is down, and for [lingerMs] after the last one lifts
 *   (flings), every frame re-samples them and diffs each scrollable's offset
 *   with its last one: a first change sends `start` (at the resting offset,
 *   with the scrollable's anchor), then `update`; [idleMs] without a change
 *   sends `end`. A scrollable first seen mid-gesture is a new baseline.
 * - Offsets are per-frame samples of what the region reports, so they are
 *   approximate (a known gap); scrolls without a touch (wheel, programmatic)
 *   are not seen, and overscroll is not reported.
 *
 * Main thread only.
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
    private class State(val id: String, var metrics: ScrollMetrics, var active: Boolean = false, var lastChangeMonoUs: Long = 0)

    private var hosts: List<RegionHost> = emptyList()
    private val states = HashMap<View, HashMap<Int, State>>()
    private var pointersDown = false
    private var watchUntilMonoUs = Long.MIN_VALUE

    fun onTouch(event: MotionEvent) {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                pointersDown = true
                hosts = findHosts()
                states.keys.retainAll(hosts.map { it.view }.toSet())
                hosts.forEach { sample(it, clock.now(), baselineOnly = true) }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                pointersDown = false
                watchUntilMonoUs = clock.now().monoUs + lingerMs * MICROS_PER_MILLI
            }
            else -> Unit
        }
        if (hosts.isNotEmpty()) requestFrame()
    }

    /** Diffs offsets and ends idle scrolls. Called once per frame. */
    fun onFrame() {
        if (hosts.isEmpty()) return
        val now = clock.now()
        val watching = pointersDown || now.monoUs < watchUntilMonoUs
        if (watching) hosts.forEach { sample(it, now, baselineOnly = false) }
        val anyActive = endIdle(now)
        if (watching || anyActive) requestFrame()
    }

    fun detach() {
        hosts = emptyList()
        states.clear()
    }

    private fun sample(host: RegionHost, at: HostTime, baselineOnly: Boolean) {
        val known = states.getOrPut(host.view) { HashMap() }
        for (scrollable in host.scrollables()) {
            val metrics = metricsOf(scrollable)
            val state = known[scrollable.key]
            if (state == null) {
                known[scrollable.key] = State(newId(host), metrics)
                continue
            }
            if (baselineOnly) {
                if (!state.active) state.metrics = metrics
                continue
            }
            if (metrics.offsetPx == state.metrics.offsetPx) continue
            if (!state.active) {
                state.active = true
                val target = AdapterGuard.run("region scroll target", null) { scrollable.target() }
                val anchor = target?.let { anchorFor(host, it) }
                emit(ScrollFacts.fact(state.id, ScrollPhase.Start, state.metrics, density(), at, anchor))
            }
            state.metrics = metrics
            state.lastChangeMonoUs = at.monoUs
            emit(ScrollFacts.fact(state.id, ScrollPhase.Update, metrics, density(), at))
        }
    }

    private fun endIdle(now: HostTime): Boolean {
        var anyActive = false
        for (state in states.values.flatMap { it.values }) {
            if (!state.active) continue
            if (now.monoUs - state.lastChangeMonoUs >= idleMs * MICROS_PER_MILLI) {
                state.active = false
                emit(ScrollFacts.fact(state.id, ScrollPhase.End, state.metrics, density(), now))
            } else {
                anyActive = true
            }
        }
        return anyActive
    }

    private fun findHosts(): List<RegionHost> {
        val found = ArrayList<RegionHost>()
        collect(root, found)
        return found
    }

    private fun collect(view: View, out: MutableList<RegionHost>) {
        if (ViewRules.isExcluded(view)) return
        val host = Regions.hostOf(view)
        if (host != null) {
            out += host
            return
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) collect(view.getChildAt(i), out)
        }
    }

    private fun metricsOf(scrollable: RegionScrollable) =
        ScrollMetrics(if (scrollable.vertical) ScrollAxis.Vertical else ScrollAxis.Horizontal, scrollable.offsetPx, scrollable.maxExtentPx)

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
