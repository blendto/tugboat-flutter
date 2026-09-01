package com.tugboat.capture.internal

import java.util.concurrent.atomic.AtomicInteger

/**
 * Hands PixelCopy destination recycle from the waiting capture thread to the
 * PixelCopy callback when the local wait ends while a copy is still in flight
 * (timeout or interrupt). That keeps [android.graphics.Bitmap.recycle] from
 * racing with an outstanding `PixelCopy.request`.
 */
internal class PixelCopyRecycleGuard(
    private val recycle: () -> Unit,
) {
    private val state = AtomicInteger(CALLER)

    fun callerOwnsAfterTimeout(): Boolean {
        while (true) {
            when (val current = state.get()) {
                CALLER -> if (state.compareAndSet(CALLER, CALLBACK)) return false
                CALLBACK -> return false
                FINISHED -> return true
                else -> return true
            }
        }
    }

    fun onCallback() {
        while (true) {
            when (val current = state.get()) {
                CALLER -> if (state.compareAndSet(CALLER, FINISHED)) return
                CALLBACK -> {
                    if (state.compareAndSet(CALLBACK, FINISHED)) {
                        recycle()
                        return
                    }
                }
                FINISHED -> return
                else -> return
            }
        }
    }

    companion object {
        const val CALLER = 0
        const val CALLBACK = 1
        const val FINISHED = 2
    }
}
