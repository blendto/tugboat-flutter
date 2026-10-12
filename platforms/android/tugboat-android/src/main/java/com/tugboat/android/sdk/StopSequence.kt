package com.tugboat.android.sdk

import android.util.Log
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * `stop()` in the order the engine needs: `session.end`, then (once the
 * `session_end` post settled, or after [maxDrainMs]) the finish step, which
 * submits `engine.dispose` and destroys the handle. `engine.dispose` is
 * rejected while a session is live, and it starts no new IO, so disposing
 * before the drain would lose `session_end` (C5).
 *
 * [finish] runs once, on a daemon `tugboat-stop` thread: it may block
 * briefly (the pixel runtime's disposal waits for its thread) and must not
 * run on the main or IO thread.
 */
internal class StopSequence(private val maxDrainMs: Long = MAX_DRAIN_MS) {
    fun run(watcher: SessionEndWatcher, endSession: () -> Unit, finish: () -> Unit) {
        val settled = CountDownLatch(1)
        watcher.whenSettled(settled::countDown)
        endSession()
        Thread({
            try {
                settled.await(maxDrainMs, TimeUnit.MILLISECONDS)
                finish()
            } catch (failure: Throwable) {
                Log.w(TAG, "stop failed", failure)
            }
        }, "tugboat-stop").apply {
            isDaemon = true
            start()
        }
    }

    companion object {
        private const val TAG = "TugboatStop"

        /**
         * The engine's `endDrainTimeoutMs` (5 s) plus one `jsonTimeoutMs`
         * (15 s) for the `session_end` post itself, plus slack for its
         * answer: past this nothing more will be delivered.
         */
        const val MAX_DRAIN_MS = 25_000L
    }
}
