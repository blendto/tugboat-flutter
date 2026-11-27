package com.tugboat.android.views.facts

import android.os.Build
import android.view.InputEvent
import android.view.KeyEvent
import android.view.MotionEvent
import com.tugboat.android.host.HostClock
import com.tugboat.android.host.HostTime

/**
 * Fact times for the adapter. Input events carry their own time in the
 * `SystemClock.uptimeMillis` timebase, the host's `monoUs` clock
 * ([com.tugboat.android.host.SystemHostClock]). `MotionEvent` times use
 * `getEventTimeNanos` only from API 35, where the host clock also reads
 * `uptimeNanos`, so both clocks have the same precision and an input fact is
 * never stamped later than a host "now" taken after it; below that both are
 * whole milliseconds. `KeyEvent` times are milliseconds. Other facts use
 * [clock] now.
 */
internal class FactClock(private val clock: HostClock) {
    fun now(): HostTime = clock.now()

    /** [event]'s time, with `wallUs` back-dated by the same amount. */
    fun at(event: InputEvent): HostTime = atMonoUs(eventMonoUs(event))

    private fun atMonoUs(monoUs: Long): HostTime {
        val now = clock.now()
        return HostTime(monoUs = monoUs, wallUs = now.wallUs - (now.monoUs - monoUs))
    }

    private fun eventMonoUs(event: InputEvent): Long =
        when {
            event is MotionEvent && Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM ->
                event.eventTimeNanos / NANOS_PER_MICRO
            event is MotionEvent -> event.eventTime * MICROS_PER_MILLI
            event is KeyEvent -> event.eventTime * MICROS_PER_MILLI
            else -> clock.now().monoUs
        }

    private companion object {
        const val NANOS_PER_MICRO = 1_000L
        const val MICROS_PER_MILLI = 1_000L
    }
}
