package com.tugboat.capture

import android.annotation.TargetApi
import android.graphics.Bitmap
import android.os.Build
import android.view.View
import com.tugboat.capture.internal.EngineSurfaceFinder
import com.tugboat.capture.internal.ImageCore
import com.tugboat.capture.internal.MaskMapper
import com.tugboat.capture.internal.PixelCopyCapture
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
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

    fun capture(view: View, request: CaptureRequest, onComplete: (CaptureResult) -> Unit) {
        if (disposed.get()) {
            onComplete(result(request, CaptureStatus.Disposed))
            return
        }
        try {
            executor.execute { runCapture(view, request, onComplete) }
        } catch (_: RejectedExecutionException) {
            onComplete(result(request, CaptureStatus.Disposed))
        }
    }

    fun cancel(requestId: Long) {
        cancelledId.set(requestId)
    }

    fun dispose() {
        if (!disposed.compareAndSet(false, true)) return
        executor.shutdownNow()
        runCatching { executor.awaitTermination(500, TimeUnit.MILLISECONDS) }
    }

    private fun runCapture(
        view: View,
        request: CaptureRequest,
        onComplete: (CaptureResult) -> Unit,
    ) {
        inFlightId.set(request.requestId)
        try {
            onComplete(captureSync(view, request))
        } finally {
            inFlightId.compareAndSet(request.requestId, NO_REQUEST)
        }
    }

    @TargetApi(Build.VERSION_CODES.N)
    private fun captureSync(view: View, request: CaptureRequest): CaptureResult {
        if (disposed.get()) return result(request, CaptureStatus.Disposed)
        if (isCancelled(request.requestId)) return result(request, CaptureStatus.Cancelled)
        if (Build.VERSION.SDK_INT < MIN_NATIVE_API) {
            return result(request, CaptureStatus.UnsupportedApi)
        }
        if (request.pixelWidth <= 0 || request.pixelHeight <= 0) {
            return result(request, CaptureStatus.ProcessingFailed)
        }

        val surface = EngineSurfaceFinder.inspect(view)
        if (surface.renderMode != RenderMode.SurfaceView || surface.surfaceView == null) {
            return result(request, CaptureStatus.UnsupportedRenderMode, surface.renderMode)
        }
        val surfaceView = surface.surfaceView

        var bitmap: Bitmap? = null
        try {
            bitmap =
                Bitmap.createBitmap(
                    request.pixelWidth,
                    request.pixelHeight,
                    Bitmap.Config.ARGB_8888,
                )
            val copyStart = System.nanoTime()
            val copyStatus =
                PixelCopyCapture.copy(surfaceView, bitmap, timeoutMs) {
                    isCurrent(request.requestId)
                }
            val surfaceCopyMicros = elapsedMicros(copyStart)
            if (!isCurrent(request.requestId)) {
                return result(request, CaptureStatus.Cancelled, surface.renderMode)
            }
            if (copyStatus != CaptureStatus.Ok) {
                return result(request, copyStatus, surface.renderMode)
                    .copy(timings = CaptureTimings(surfaceCopyMicros = surfaceCopyMicros))
            }

            val masks = MaskMapper.toPixelRects(request.masks, bitmap.width, bitmap.height)
            val processed =
                try {
                    ImageCore.process(bitmap, masks, request.lastDHash, request.force)
                } catch (_: Throwable) {
                    return result(request, CaptureStatus.ProcessingFailed, surface.renderMode)
                }
            val coreStatus = mapCoreStatus(processed.status)
            if (coreStatus != CaptureStatus.Ok && coreStatus != CaptureStatus.SkippedByDHash) {
                return result(request, coreStatus, surface.renderMode)
            }
            if (coreStatus == CaptureStatus.SkippedByDHash) {
                return CaptureResult(
                    requestId = request.requestId,
                    status = CaptureStatus.SkippedByDHash,
                    coverage = CaptureCoverage.EngineSurface,
                    width = bitmap.width,
                    height = bitmap.height,
                    dHash = processed.dHash,
                    timings =
                        CaptureTimings(
                            surfaceCopyMicros = surfaceCopyMicros,
                            maskFillMicros = processed.maskFillMicros,
                            dHashMicros = processed.dHashMicros,
                        ),
                    renderMode = surface.renderMode,
                )
            }

            val jpegStart = System.nanoTime()
            val jpeg = encodeJpeg(bitmap)
            val jpegMicros = elapsedMicros(jpegStart)
            val shaStart = System.nanoTime()
            val digest = sha256Hex(jpeg)
            val shaMicros = elapsedMicros(shaStart)
            return CaptureResult(
                requestId = request.requestId,
                status = CaptureStatus.Ok,
                coverage = CaptureCoverage.EngineSurface,
                jpeg = jpeg,
                width = bitmap.width,
                height = bitmap.height,
                dHash = processed.dHash,
                contentHash = digest,
                timings =
                    CaptureTimings(
                        surfaceCopyMicros = surfaceCopyMicros,
                        maskFillMicros = processed.maskFillMicros,
                        dHashMicros = processed.dHashMicros,
                        jpegMicros = jpegMicros,
                        sha256Micros = shaMicros,
                    ),
                renderMode = surface.renderMode,
            )
        } finally {
            bitmap?.recycle()
        }
    }

    private fun isCancelled(requestId: Long): Boolean = cancelledId.get() == requestId

    private fun isCurrent(requestId: Long): Boolean =
        !disposed.get() && !isCancelled(requestId) && inFlightId.get() == requestId

    private fun encodeJpeg(bitmap: Bitmap): ByteArray {
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, stream)
        return stream.toByteArray()
    }

    private fun sha256Hex(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        val out = StringBuilder(digest.size * 2)
        for (b in digest) {
            out.append(String.format("%02x", b))
        }
        return out.toString()
    }

    private fun elapsedMicros(startNs: Long): Long = (System.nanoTime() - startNs) / 1_000

    private fun result(
        request: CaptureRequest,
        status: CaptureStatus,
        renderMode: RenderMode = RenderMode.Unknown,
    ): CaptureResult =
        CaptureResult(requestId = request.requestId, status = status, renderMode = renderMode)

    private fun mapCoreStatus(code: Int): CaptureStatus =
        when (code) {
            0 -> CaptureStatus.Ok
            1 -> CaptureStatus.SkippedByDHash
            else -> CaptureStatus.ProcessingFailed
        }

    companion object {
        const val MIN_NATIVE_API: Int = 24
        const val DEFAULT_TIMEOUT_MS: Long = 2_000
        const val JPEG_QUALITY: Int = 80
        private const val NO_REQUEST: Long = -1L
    }
}
