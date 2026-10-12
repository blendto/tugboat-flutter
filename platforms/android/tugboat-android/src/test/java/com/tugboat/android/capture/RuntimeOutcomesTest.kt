package com.tugboat.android.capture

import com.tugboat.android.host.DHashBaseline
import com.tugboat.android.host.FrameHandleTable
import com.tugboat.capture.CaptureResult
import com.tugboat.capture.CaptureStatus
import com.tugboat.capture.CaptureTimings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Every `capture-runtime` status maps to one explicit `capture.result`. */
class RuntimeOutcomesTest {
    private val frames = FrameHandleTable()
    private var now = 9_000_000L
    private val outcomes = RuntimeOutcomes(frames) { now }

    private fun inFlight(baseline: DHashBaseline? = null) = InFlightCapture(
        requestId = "capture-7",
        geometry = CaptureGeometry(1080, 2400, 2.0f),
        structureSignature = "sig",
        offeredBaseline = baseline,
        masked = true,
        frameWaitMicros = 10,
        maskMicros = 20,
        startedNanos = 1_000_000L,
    )

    private fun result(status: CaptureStatus, jpeg: ByteArray = ByteArray(0)) = CaptureResult(
        requestId = 1,
        status = status,
        jpeg = jpeg,
        width = 405,
        height = 900,
        dHash = "0f0f",
        contentHash = "sha",
        timings = CaptureTimings(surfaceCopyMicros = 100, maskFillMicros = 5, dHashMicros = 6, jpegMicros = 300, sha256Micros = 7),
    )

    @Test
    fun okStoresTheJpegAndReportsTheFrame() {
        val answer = outcomes.answer(inFlight(), result(CaptureStatus.Ok, byteArrayOf(1, 2, 3))) as CaptureAnswer.Captured

        assertEquals(3, frames[answer.frame.handle]?.size)
        assertEquals(CapturedFrame(answer.frame.handle, 405, 900, "sha", true, 3, 8_000, "0f0f", "sig"), answer.frame)
        assertEquals(BoundaryRect(0.0, 0.0, 540.0, 1200.0), answer.boundaryRect)
        assertEquals(CaptureTimingsMicros(frameWaitMicros = 10, readbackMicros = 100, maskMicros = 31, encodeMicros = 307), answer.timings)
    }

    @Test
    fun failuresAreMappedExplicitly() {
        val expected = mapOf(
            CaptureStatus.SecureWindow to CaptureFailure.ReadbackFailed,
            CaptureStatus.UnsupportedApi to CaptureFailure.BoundaryUnavailable,
            CaptureStatus.SurfaceUnavailable to CaptureFailure.BoundaryUnavailable,
            CaptureStatus.UnsupportedRenderMode to CaptureFailure.BoundaryUnavailable,
            CaptureStatus.Timeout to CaptureFailure.PaintTimedOut,
            CaptureStatus.PixelCopyFailed to CaptureFailure.ReadbackFailed,
            CaptureStatus.ProcessingFailed to CaptureFailure.EncodingFailed,
            CaptureStatus.Ok to CaptureFailure.EncodingFailed, // no bytes
            CaptureStatus.SkippedByDHash to CaptureFailure.ReadbackFailed, // no baseline was offered
        )
        for ((status, failure) in expected) {
            val answer = outcomes.answer(inFlight(), result(status))
            assertEquals(status.name, failure, (answer as CaptureAnswer.Failed).failure)
        }
        assertEquals("a failure stores no frame", 0, frames.size)
    }

    @Test
    fun cancelledAndDisposedAreCancelled() {
        for (status in listOf(CaptureStatus.Cancelled, CaptureStatus.Disposed)) {
            assertEquals(CaptureAnswer.Cancelled("capture-7"), outcomes.answer(inFlight(), result(status)))
        }
    }

    @Test
    fun everyStatusIsCovered() {
        CaptureStatus.values().forEach { status ->
            val answer = outcomes.answer(inFlight(DHashBaseline("aa", "sig")), result(status, byteArrayOf(1)))
            assertEquals("capture-7", answer.requestId)
        }
    }

    @Test
    fun aSkipWithABaselineIsCapturedAsTheBaseline() {
        val answer = outcomes.answer(inFlight(DHashBaseline("aaaa", "sig")), result(CaptureStatus.SkippedByDHash))

        val frame = (answer as CaptureAnswer.Captured).frame
        assertEquals("aaaa", frame.dHash)
        assertEquals("sig", frame.structureSignature)
        assertEquals(0, frame.byteLength)
        assertTrue("an empty handle the engine releases", frames[frame.handle]!!.isEmpty())
    }
}
