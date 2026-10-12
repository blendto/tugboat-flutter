package com.tugboat.android.capture

import com.tugboat.android.host.DHashBaseline
import com.tugboat.android.host.FrameHandleTable
import com.tugboat.capture.CaptureResult
import com.tugboat.capture.CaptureStatus

/** What the host knew when it asked the runtime for one capture. */
internal class InFlightCapture(
    val requestId: String,
    val geometry: CaptureGeometry,
    val structureSignature: String,
    /** The engine's baseline, only when its structure equals [structureSignature]. */
    val offeredBaseline: DHashBaseline?,
    val masked: Boolean,
    val frameWaitMicros: Long,
    val maskMicros: Long,
    val startedNanos: Long,
)

/**
 * Turns a `capture-runtime` [CaptureResult] into the `capture.result`
 * answer, explicitly per [CaptureStatus]:
 *
 * | Runtime status | Answer |
 * | --- | --- |
 * | `Ok` with JPEG bytes | `captured` (bytes stored in the handle table) |
 * | `SkippedByDHash` | `captured` with `dHash` equal to the offered baseline (the engine coalesces it and releases the empty handle); without a baseline `failed readbackFailed` |
 * | `SecureWindow` | `failed readbackFailed`: `FLAG_SECURE` windows are never copied |
 * | `UnsupportedApi`, `SurfaceUnavailable`, `UnsupportedRenderMode` | `failed boundaryUnavailable` |
 * | `Timeout` | `failed paintTimedOut` |
 * | `PixelCopyFailed` | `failed readbackFailed` |
 * | `ProcessingFailed`, `Ok` without bytes | `failed encodingFailed` |
 * | `Cancelled`, `Disposed` | `cancelled` |
 */
internal class RuntimeOutcomes(private val frames: FrameHandleTable, private val nanoTime: () -> Long) {
    fun answer(capture: InFlightCapture, result: CaptureResult): CaptureAnswer {
        val id = capture.requestId
        return when (result.status) {
            CaptureStatus.Ok ->
                if (result.jpeg.isEmpty()) failed(capture, result, CaptureFailure.EncodingFailed) else captured(capture, result)
            CaptureStatus.SkippedByDHash -> coalesced(capture, result)
            CaptureStatus.SecureWindow -> failed(capture, result, CaptureFailure.ReadbackFailed)
            CaptureStatus.UnsupportedApi,
            CaptureStatus.SurfaceUnavailable,
            CaptureStatus.UnsupportedRenderMode,
            -> failed(capture, result, CaptureFailure.BoundaryUnavailable)
            CaptureStatus.Timeout -> failed(capture, result, CaptureFailure.PaintTimedOut)
            CaptureStatus.PixelCopyFailed -> failed(capture, result, CaptureFailure.ReadbackFailed)
            CaptureStatus.ProcessingFailed -> failed(capture, result, CaptureFailure.EncodingFailed)
            CaptureStatus.Cancelled, CaptureStatus.Disposed -> CaptureAnswer.Cancelled(id)
        }
    }

    private fun captured(capture: InFlightCapture, result: CaptureResult): CaptureAnswer {
        val handle = frames.put(result.jpeg)
        return CaptureAnswer.Captured(
            requestId = capture.requestId,
            frame = frame(capture, result, handle, result.jpeg.size, result.dHash, result.contentHash),
            boundaryRect = capture.geometry.boundaryRect,
            timings = timings(capture, result),
        )
    }

    /**
     * The runtime matched the baseline within Hamming distance 2 and encoded
     * nothing. The engine applies `perceptual_hash_coalesced` only when the
     * reported dHash and structure equal its baseline, so that is what is
     * reported; the empty handle is released by the engine.
     */
    private fun coalesced(capture: InFlightCapture, result: CaptureResult): CaptureAnswer {
        val baseline = capture.offeredBaseline ?: return failed(capture, result, CaptureFailure.ReadbackFailed)
        val handle = frames.put(ByteArray(0))
        return CaptureAnswer.Captured(
            requestId = capture.requestId,
            frame = frame(capture, result, handle, 0, baseline.dHash, contentHash = ""),
            boundaryRect = capture.geometry.boundaryRect,
            timings = timings(capture, result),
        )
    }

    private fun frame(
        capture: InFlightCapture,
        result: CaptureResult,
        handle: String,
        byteLength: Int,
        dHash: String,
        contentHash: String,
    ) = CapturedFrame(
        handle = handle,
        width = result.width,
        height = result.height,
        contentHash = contentHash,
        masked = capture.masked,
        byteLength = byteLength,
        captureMicros = (nanoTime() - capture.startedNanos) / NANOS_PER_MICRO,
        dHash = dHash,
        structureSignature = capture.structureSignature,
    )

    private fun failed(capture: InFlightCapture, result: CaptureResult, failure: CaptureFailure) =
        CaptureAnswer.Failed(capture.requestId, failure, timings(capture, result))

    private fun timings(capture: InFlightCapture, result: CaptureResult): CaptureTimingsMicros {
        val t = result.timings
        return CaptureTimingsMicros(
            frameWaitMicros = capture.frameWaitMicros,
            readbackMicros = t.surfaceCopyMicros + t.pixelReadbackMicros,
            maskMicros = capture.maskMicros + t.maskFillMicros + t.dHashMicros,
            encodeMicros = t.jpegMicros + t.sha256Micros,
        )
    }

    private companion object {
        const val NANOS_PER_MICRO = 1_000L
    }
}
