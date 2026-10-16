package com.tugboat.capture

import android.os.Build
import android.view.View
import android.view.Window
import com.tugboat.capture.internal.CapturePipeline
import com.tugboat.capture.internal.CaptureSource
import com.tugboat.capture.internal.FlutterSurfaceSource
import com.tugboat.capture.internal.RuntimeConstants
import com.tugboat.capture.internal.WindowSource
import com.tugboat.capture.internal.framelessResult
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class CaptureRuntime(
    private val timeoutMs: Long = DEFAULT_TIMEOUT_MS,
) {
    private val executor: ExecutorService =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "tugboat-capture").apply { isDaemon = true }
        }
    private val pipeline = CapturePipeline(timeoutMs)
    private val disposed = AtomicBoolean(false)
    private val inFlightId = AtomicLong(NO_REQUEST)
    private val cancelledId = AtomicLong(NO_REQUEST)

    fun capabilities(): CaptureCapabilities {
        val api = Build.VERSION.SDK_INT
        return CaptureCapabilities(
            nativeCaptureSupported = api >= MIN_NATIVE_API,
            apiLevel = api,
        )
    }

    /** `PixelCopy` of the active `FlutterSurfaceView` under [view]. Coverage `EngineSurface`. */
    fun capture(view: View, request: CaptureRequest, onComplete: (CaptureResult) -> Unit) {
        enqueue(FlutterSurfaceSource(view), request, onComplete)
    }

    /**
     * `PixelCopy` of one app [window]'s surface (API [MIN_WINDOW_API]+; below
     * that `UnsupportedApi`). Coverage `WindowComposite`. Masks are normalized
     * to the window's decor view.
     *
     * The copy holds the views drawn into that window, `TextureView`
     * included. It is not the full-screen composition: `SurfaceView` /
     * `GLSurfaceView` layers (video, camera previews, maps) and every other
     * window (dialogs, popups, dropdowns, the IME) are missing.
     *
     * A window flagged `FLAG_SECURE` when the copy is issued is never copied
     * and returns `SecureWindow`. The copy is taken from a frame committed
     * after that check, so a screen drawn while the flag was set is not
     * copied after the flag is cleared.
     */
    fun capture(window: Window, request: CaptureRequest, onComplete: (CaptureResult) -> Unit) =
        capture(window, request, { MaskSnapshot(request.masks) }, onComplete)

    /**
     * [capture] of [window] with masks computed for the frame being copied:
     * [masks] runs on the main thread right after the committed-frame wait and
     * the `FLAG_SECURE` re-check, immediately before `PixelCopy.request`, and
     * its masks replace `request.masks`. The result carries the snapshot it
     * returned (`CaptureResult.maskSnapshot`).
     */
    fun capture(
        window: Window,
        request: CaptureRequest,
        masks: WindowMaskSupplier,
        onComplete: (CaptureResult) -> Unit,
    ) {
        enqueue(WindowSource(window, masks), request, onComplete)
    }

    fun cancel(requestId: Long) {
        cancelledId.set(requestId)
    }

    fun dispose() {
        if (!disposed.compareAndSet(false, true)) return
        executor.shutdownNow()
        runCatching { executor.awaitTermination(500, TimeUnit.MILLISECONDS) }
    }

    private fun enqueue(
        source: CaptureSource,
        request: CaptureRequest,
        onComplete: (CaptureResult) -> Unit,
    ) {
        if (disposed.get()) {
            onComplete(framelessResult(request, CaptureStatus.Disposed))
            return
        }
        try {
            executor.execute { runCapture(source, request, onComplete) }
        } catch (_: RejectedExecutionException) {
            onComplete(framelessResult(request, CaptureStatus.Disposed))
        }
    }

    private fun runCapture(
        source: CaptureSource,
        request: CaptureRequest,
        onComplete: (CaptureResult) -> Unit,
    ) {
        inFlightId.set(request.requestId)
        try {
            onComplete(captureSync(source, request))
        } finally {
            inFlightId.compareAndSet(request.requestId, NO_REQUEST)
        }
    }

    private fun captureSync(source: CaptureSource, request: CaptureRequest): CaptureResult {
        if (disposed.get()) return framelessResult(request, CaptureStatus.Disposed)
        if (isCancelled(request.requestId)) return framelessResult(request, CaptureStatus.Cancelled)
        return pipeline.capture(source, request) { isCurrent(request.requestId) }
    }

    private fun isCancelled(requestId: Long): Boolean = cancelledId.get() == requestId

    private fun isCurrent(requestId: Long): Boolean =
        !disposed.get() && !isCancelled(requestId) && inFlightId.get() == requestId

    companion object {
        const val MIN_NATIVE_API: Int = RuntimeConstants.MIN_NATIVE_API
        const val MIN_WINDOW_API: Int = RuntimeConstants.MIN_WINDOW_API
        const val DEFAULT_TIMEOUT_MS: Long = 2_000
        const val JPEG_QUALITY: Int = RuntimeConstants.JPEG_QUALITY
        private const val NO_REQUEST: Long = -1L
    }
}
