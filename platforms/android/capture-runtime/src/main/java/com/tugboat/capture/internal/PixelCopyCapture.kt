package com.tugboat.capture.internal

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import com.tugboat.capture.CaptureStatus
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

internal data class PixelCopyOutcome(
    val status: CaptureStatus,
    val callerOwnsDestination: Boolean = true,
)

/** Copies a resolved target into a caller-allocated bitmap. */
internal fun interface FrameCopier {
    fun copy(
        target: PixelCopyTarget,
        destination: Bitmap,
        timeoutMs: Long,
        isCurrent: () -> Boolean,
    ): PixelCopyOutcome
}

internal object PixelCopyCapture : FrameCopier {
    override fun copy(
        target: PixelCopyTarget,
        destination: Bitmap,
        timeoutMs: Long,
        isCurrent: () -> Boolean,
    ): PixelCopyOutcome {
        if (!target.isAvailable()) {
            return PixelCopyOutcome(CaptureStatus.SurfaceUnavailable)
        }
        val latch = CountDownLatch(1)
        val code = AtomicInteger(Int.MIN_VALUE)
        val handler = Handler(Looper.getMainLooper())
        val guard =
            PixelCopyRecycleGuard {
                if (!destination.isRecycled) {
                    destination.recycle()
                }
            }
        val notIssued = AtomicReference(CaptureStatus.Ok)
        handler.post {
            if (!isCurrent()) {
                latch.countDown()
                guard.onCallback()
                return@post
            }
            val issued =
                try {
                    target.issue(
                        destination,
                        { result ->
                            code.set(result)
                            latch.countDown()
                            guard.onCallback()
                        },
                        handler,
                    )
                } catch (_: IllegalArgumentException) {
                    CaptureStatus.PixelCopyFailed
                }
            if (issued != CaptureStatus.Ok) {
                notIssued.set(issued)
                latch.countDown()
                guard.onCallback()
            }
        }
        val completed =
            try {
                latch.await(timeoutMs, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                false
            }
        val callerOwnsDestination =
            if (completed) {
                true
            } else {
                guard.callerOwnsAfterTimeout()
            }
        val status =
            when {
                !isCurrent() -> CaptureStatus.Cancelled
                !completed -> CaptureStatus.Timeout
                notIssued.get() != CaptureStatus.Ok -> notIssued.get()
                else ->
                    when (code.get()) {
                        PixelCopy.SUCCESS -> CaptureStatus.Ok
                        PixelCopy.ERROR_TIMEOUT -> CaptureStatus.Timeout
                        Int.MIN_VALUE -> CaptureStatus.Timeout
                        else -> CaptureStatus.PixelCopyFailed
                    }
            }
        return PixelCopyOutcome(status, callerOwnsDestination)
    }
}
