package com.tugboat.capture.internal

import android.annotation.TargetApi
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.SurfaceView
import com.tugboat.capture.CaptureStatus
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

internal data class PixelCopyOutcome(
    val status: CaptureStatus,
    val callerOwnsDestination: Boolean = true,
)

internal object PixelCopyCapture {
    @TargetApi(Build.VERSION_CODES.N)
    fun copy(
        surfaceView: SurfaceView,
        destination: Bitmap,
        timeoutMs: Long,
        isCurrent: () -> Boolean,
    ): PixelCopyOutcome {
        if (!surfaceView.holder.surface.isValid) {
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
        handler.post {
            if (!isCurrent()) {
                latch.countDown()
                guard.onCallback()
                return@post
            }
            try {
                PixelCopy.request(
                    surfaceView,
                    destination,
                    { result ->
                        code.set(result)
                        latch.countDown()
                        guard.onCallback()
                    },
                    handler,
                )
            } catch (_: IllegalArgumentException) {
                code.set(PixelCopy.ERROR_SOURCE_INVALID)
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
