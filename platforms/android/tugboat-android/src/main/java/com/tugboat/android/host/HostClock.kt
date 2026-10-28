package com.tugboat.android.host

import android.os.Build
import android.os.SystemClock

/** A message timestamp: the engine's `at` object. */
internal data class HostTime(val monoUs: Long, val wallUs: Long) {
    fun toJson(): String = "{\"monoUs\":$monoUs,\"wallUs\":$wallUs}"
}

/** The host clock every message and timer uses (stateful-engine.md section 5). */
internal fun interface HostClock {
    fun now(): HostTime
}

/**
 * `monoUs` is the `SystemClock.uptimeMillis` timebase in microseconds, the
 * clock `MotionEvent.getEventTime()` and `Handler.postAtTime` use. `wallUs` is
 * UTC epoch microseconds.
 */
internal object SystemHostClock : HostClock {
    override fun now(): HostTime = HostTime(monoUs(), System.currentTimeMillis() * 1000)

    private fun monoUs(): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            SystemClock.uptimeNanos() / 1000
        } else {
            SystemClock.uptimeMillis() * 1000
        }
}
