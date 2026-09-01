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

internal object PixelCopyCapture {
    @TargetApi(Build.VERSION_CODES.N)
    fun copy(
        surfaceView: SurfaceView,
        destination: Bitmap,
        timeoutMs: Long,
        isCurrent: () -> Boolean,
    ): CaptureStatus {
        if (!surfaceView.holder.surface.isValid) {
            return CaptureStatus.SurfaceUnavailable
        }
        val latch = CountDownLatch(1)
        val code = AtomicInteger(Int.MIN_VALUE)
        val handler = Handler(Looper.getMainLooper())
        handler.post {
            if (!isCurrent()) {
                latch.countDown()
                return@post
            }
            PixelCopy.request(
                surfaceView,
                destination,
                { result ->
                    code.set(result)
                    latch.countDown()
                },
                handler,
            )
        }
        val completed = latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        if (!completed) {
            // PixelCopy may still write to `destination`. Block until the
            // callback runs so CaptureRuntime's finally can recycle safely.
            latch.await()
        }
        if (!isCurrent()) return CaptureStatus.Cancelled
        if (!completed) return CaptureStatus.Timeout
        return when (code.get()) {
            PixelCopy.SUCCESS -> CaptureStatus.Ok
            PixelCopy.ERROR_TIMEOUT -> CaptureStatus.Timeout
            Int.MIN_VALUE -> CaptureStatus.Timeout
            else -> CaptureStatus.PixelCopyFailed
        }
    }
}
