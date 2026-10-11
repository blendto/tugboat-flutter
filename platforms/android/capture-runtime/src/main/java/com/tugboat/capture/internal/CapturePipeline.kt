package com.tugboat.capture.internal

import android.graphics.Bitmap
import android.os.Build
import com.tugboat.capture.CaptureRequest
import com.tugboat.capture.CaptureResult
import com.tugboat.capture.CaptureRuntime
import com.tugboat.capture.CaptureStatus
import com.tugboat.capture.CaptureTimings
import com.tugboat.capture.RenderMode
import java.io.ByteArrayOutputStream
import java.security.MessageDigest

/** Masks, dHash and skip on a copied bitmap (the C++ core behind JNI). */
internal fun interface FrameCore {
    fun process(
        bitmap: Bitmap,
        masksPacked: IntArray,
        lastDHash: String,
        force: Boolean,
    ): NativeProcessResult
}

/**
 * The one capture pipeline: API floor, size check, source resolve, PixelCopy,
 * mask fill + dHash in the C++ core, JPEG q80, SHA-256 and timings. Every
 * [CaptureSource] runs through it; only the source differs.
 *
 * Runs on the runtime's single capture thread.
 */
internal class CapturePipeline(
    private val timeoutMs: Long,
    private val copier: FrameCopier = PixelCopyCapture,
    // A lambda, not ImageCore itself, so the JNI library loads on first use.
    private val core: FrameCore = FrameCore { bitmap, masks, lastDHash, force ->
        ImageCore.process(bitmap, masks, lastDHash, force)
    },
) {
    fun capture(
        source: CaptureSource,
        request: CaptureRequest,
        isCurrent: () -> Boolean,
    ): CaptureResult {
        if (Build.VERSION.SDK_INT < source.minApi) {
            return framelessResult(request, CaptureStatus.UnsupportedApi)
        }
        if (request.pixelWidth <= 0 || request.pixelHeight <= 0) {
            return framelessResult(request, CaptureStatus.ProcessingFailed)
        }
        return when (val resolved = source.resolve()) {
            is SourceResolution.Rejected -> framelessResult(request, resolved.status, resolved.renderMode)
            is SourceResolution.Ready -> copyAndProcess(source, resolved, request, isCurrent)
        }
    }

    private fun copyAndProcess(
        source: CaptureSource,
        resolved: SourceResolution.Ready,
        request: CaptureRequest,
        isCurrent: () -> Boolean,
    ): CaptureResult {
        val renderMode = resolved.renderMode
        var bitmap: Bitmap? = null
        var recycleBitmap = true
        try {
            bitmap =
                Bitmap.createBitmap(
                    request.pixelWidth,
                    request.pixelHeight,
                    Bitmap.Config.ARGB_8888,
                )
            val copyStart = System.nanoTime()
            val copy = copier.copy(resolved.target, bitmap, timeoutMs, isCurrent)
            recycleBitmap = copy.callerOwnsDestination
            val surfaceCopyMicros = elapsedMicros(copyStart)
            if (!isCurrent()) {
                return framelessResult(request, CaptureStatus.Cancelled, renderMode)
            }
            if (copy.status != CaptureStatus.Ok) {
                return framelessResult(request, copy.status, renderMode)
                    .copy(timings = CaptureTimings(surfaceCopyMicros = surfaceCopyMicros))
            }
            return process(source, bitmap, request, renderMode, surfaceCopyMicros)
        } finally {
            if (recycleBitmap) {
                bitmap?.recycle()
            }
        }
    }

    private fun process(
        source: CaptureSource,
        bitmap: Bitmap,
        request: CaptureRequest,
        renderMode: RenderMode,
        surfaceCopyMicros: Long,
    ): CaptureResult {
        val masks = MaskMapper.toPixelRects(request.masks, bitmap.width, bitmap.height)
        val processed =
            try {
                core.process(bitmap, masks, request.lastDHash, request.force)
            } catch (_: Throwable) {
                return framelessResult(request, CaptureStatus.ProcessingFailed, renderMode)
            }
        val coreStatus = mapCoreStatus(processed.status)
        if (coreStatus != CaptureStatus.Ok && coreStatus != CaptureStatus.SkippedByDHash) {
            return framelessResult(request, coreStatus, renderMode)
        }
        val frame =
            CaptureResult(
                requestId = request.requestId,
                status = coreStatus,
                coverage = source.coverage,
                width = bitmap.width,
                height = bitmap.height,
                dHash = processed.dHash,
                timings =
                    CaptureTimings(
                        surfaceCopyMicros = surfaceCopyMicros,
                        maskFillMicros = processed.maskFillMicros,
                        dHashMicros = processed.dHashMicros,
                    ),
                renderMode = renderMode,
            )
        if (coreStatus == CaptureStatus.SkippedByDHash) return frame
        return encode(frame, bitmap)
    }

    private fun encode(
        frame: CaptureResult,
        bitmap: Bitmap,
    ): CaptureResult {
        val jpegStart = System.nanoTime()
        val jpeg = encodeJpeg(bitmap)
        val jpegMicros = elapsedMicros(jpegStart)
        val shaStart = System.nanoTime()
        val digest = sha256Hex(jpeg)
        val shaMicros = elapsedMicros(shaStart)
        return frame.copy(
            jpeg = jpeg,
            contentHash = digest,
            timings = frame.timings.copy(jpegMicros = jpegMicros, sha256Micros = shaMicros),
        )
    }

    private fun encodeJpeg(bitmap: Bitmap): ByteArray {
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, CaptureRuntime.JPEG_QUALITY, stream)
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

    private fun mapCoreStatus(code: Int): CaptureStatus =
        when (code) {
            0 -> CaptureStatus.Ok
            1 -> CaptureStatus.SkippedByDHash
            else -> CaptureStatus.ProcessingFailed
        }
}

/** A frameless result: no coverage, no JPEG. */
internal fun framelessResult(
    request: CaptureRequest,
    status: CaptureStatus,
    renderMode: RenderMode = RenderMode.Unknown,
): CaptureResult = CaptureResult(requestId = request.requestId, status = status, renderMode = renderMode)
