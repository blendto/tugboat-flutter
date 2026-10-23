package com.tugboat.android.capture

import com.tugboat.android.host.DHashBaseline
import com.tugboat.android.host.FrameHandleTable
import com.tugboat.capture.CaptureResult
import com.tugboat.capture.CaptureStatus

/** What the host knew when it asked the runtime for one capture. */
internal class InFlightCapture(
    val requestId: String,
    /** The decor size when the request reached the main thread; the boundary when the copy was never reached. */
    val requestGeometry: CaptureGeometry,
    /** The masks, structure, and boundary taken at copy time. */
    val masks: FrameMasks,
    /** The engine's baseline, offered for requests that are not forced. */
    val offeredBaseline: DHashBaseline?,
    val frameWaitMicros: Long,
    val startedNanos: Long,
)

/**
 * Turns a `capture-runtime` [CaptureResult] into the `capture.result`
 * answer, explicitly per [CaptureStatus]:
 *
 * | Runtime status | Answer |
 * | --- | --- |
 * | `Ok` with JPEG bytes | `captured` (bytes stored in the handle table) |
 * | `SkippedByDHash` | `captured` with the offered baseline's `dHash` and structure (the runtime skips only when the copy-time structure equals it; the engine coalesces and releases the empty handle); without a baseline `failed readbackFailed` |
 * | `SecureWindow` | `failed secureWindow`: `FLAG_SECURE` windows are never copied (the engine records a throttled `capture_diagnostic`) |
 * | `UnsupportedApi`, `SurfaceUnavailable`, `UnsupportedRenderMode` | `failed boundaryUnavailable` |
 * | `Timeout` | `failed paintTimedOut` |
 * | `PixelCopyFailed` | `failed readbackFailed` |
 * | `ProcessingFailed`, `Ok` without bytes | `failed encodingFailed` |
 * | `Cancelled`, `Disposed` | `cancelled` |
 */
internal class RuntimeOutcomes(private val frames: FrameHandleTable, private val nanoTime: () -> Long) {
    fun answer(capture: InFlightCapture, result: CaptureResult): CaptureAnswer =
        when (result.status) {
            CaptureStatus.Ok ->
                if (result.jpeg.isEmpty()) failed(capture, result, CaptureFailure.EncodingFailed) else captured(capture, result)
            CaptureStatus.SkippedByDHash -> coalesced(capture, result)
            CaptureStatus.SecureWindow -> failed(capture, result, CaptureFailure.SecureWindow)
            CaptureStatus.UnsupportedApi,
            CaptureStatus.SurfaceUnavailable,
            CaptureStatus.UnsupportedRenderMode,
            -> failed(capture, result, CaptureFailure.BoundaryUnavailable)
            CaptureStatus.Timeout -> failed(capture, result, CaptureFailure.PaintTimedOut)
            CaptureStatus.PixelCopyFailed -> failed(capture, result, CaptureFailure.ReadbackFailed)
            CaptureStatus.ProcessingFailed -> failed(capture, result, CaptureFailure.EncodingFailed)
            CaptureStatus.Cancelled, CaptureStatus.Disposed -> CaptureAnswer.Cancelled(capture.requestId)
        }

    private fun captured(capture: InFlightCapture, result: CaptureResult): CaptureAnswer {
        val handle = frames.put(result.jpeg)
        val structure = capture.masks.applied.structureSignature
        return capturedAnswer(capture, result, handle, result.jpeg.size, result.dHash, structure, result.contentHash)
    }

    /**
     * The runtime matched the baseline within Hamming distance 2 under the
     * same structure and encoded nothing. The engine applies
     * `perceptual_hash_coalesced` only when the reported dHash and structure
     * equal its baseline, so that is what is reported.
     */
    private fun coalesced(capture: InFlightCapture, result: CaptureResult): CaptureAnswer {
        val baseline = capture.offeredBaseline ?: return failed(capture, result, CaptureFailure.ReadbackFailed)
        val handle = frames.put(ByteArray(0))
        return capturedAnswer(capture, result, handle, 0, baseline.dHash, baseline.structureSignature, contentHash = "")
    }

    private fun capturedAnswer(
        capture: InFlightCapture,
        result: CaptureResult,
        handle: String,
        byteLength: Int,
        dHash: String,
        structureSignature: String,
        contentHash: String,
    ): CaptureAnswer {
        val masks = capture.masks.applied
        return CaptureAnswer.Captured(
            requestId = capture.requestId,
            frame = CapturedFrame(
                handle = handle,
                width = result.width,
                height = result.height,
                contentHash = contentHash,
                masked = masks.rects.isNotEmpty(),
                byteLength = byteLength,
                captureMicros = (nanoTime() - capture.startedNanos) / NANOS_PER_MICRO,
                dHash = dHash,
                structureSignature = structureSignature,
                maskCoverage = masks.coverage,
                hasRegionHosts = masks.hasRegionHosts,
            ),
            boundaryRect = (capture.masks.geometry ?: capture.requestGeometry).boundaryRect,
            timings = timings(capture, result),
        )
    }

    private fun failed(capture: InFlightCapture, result: CaptureResult, failure: CaptureFailure) =
        CaptureAnswer.Failed(capture.requestId, failure, timings(capture, result))

    private fun timings(capture: InFlightCapture, result: CaptureResult): CaptureTimingsMicros {
        val t = result.timings
        return CaptureTimingsMicros(
            frameWaitMicros = capture.frameWaitMicros,
            readbackMicros = t.surfaceCopyMicros + t.pixelReadbackMicros,
            maskMicros = t.maskComputeMicros + t.maskFillMicros + t.dHashMicros,
            encodeMicros = t.jpegMicros + t.sha256Micros,
        )
    }

    private companion object {
        const val NANOS_PER_MICRO = 1_000L
    }
}
