package com.tugboat.android.host

import android.os.Handler

/**
 * Executes `timer.schedule` / `timer.cancel` on the engine looper. The
 * engine's `atMonoUs` is in the `SystemClock.uptimeMillis` timebase (see
 * [SystemHostClock]), which is the clock `Handler.postAtTime` uses.
 *
 * Confined to the [handler]'s thread.
 */
internal class TimerExecutor(
    private val handler: Handler,
    private val onFired: (timerId: String) -> Unit,
) {
    private val pending = HashMap<String, Runnable>()

    val scheduledCount: Int
        get() = pending.size

    /** Schedules [timerId]; an existing timer with the same id is replaced. */
    fun schedule(timerId: String, atMonoUs: Long) {
        cancel(timerId)
        val fire = Runnable {
            pending.remove(timerId)
            onFired(timerId)
        }
        pending[timerId] = fire
        handler.postAtTime(fire, uptimeMillisAt(atMonoUs))
    }

    fun cancel(timerId: String) {
        pending.remove(timerId)?.let(handler::removeCallbacks)
    }

    fun cancelAll() {
        pending.values.forEach(handler::removeCallbacks)
        pending.clear()
    }

    private companion object {
        /** Rounds up so a timer never fires before its deadline. */
        fun uptimeMillisAt(monoUs: Long): Long = Math.floorDiv(monoUs + 999, 1000L)
    }
}
