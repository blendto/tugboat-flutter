package com.tugboat.android.capture

import com.tugboat.android.host.DHashBaseline
import com.tugboat.android.host.FrameHandleTable
import com.tugboat.android.views.mask.MaskCoverage
import com.tugboat.android.views.mask.MaskMode
import com.tugboat.android.toolkit.MaskCoverageReason
import com.tugboat.android.views.mask.MaskRect
import com.tugboat.android.views.mask.WindowMaskResult
import com.tugboat.capture.CaptureResult
import com.tugboat.capture.CaptureStatus
import com.tugboat.capture.CaptureTimings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Every `capture-runtime` status maps to one explicit `capture.result`. */
@RunWith(RobolectricTestRunner::class)
class RuntimeOutcomesTest {
    private val frames = FrameHandleTable()
    private val outcomes = RuntimeOutcomes(frames) { 9_000_000L }
    private val coverage = MaskCoverage(MaskMode.Precise, setOf(MaskCoverageReason.WebView))
    private val window = laidOutWindow(widthPx = 1080, heightPx = 2400)

    /** A capture whose masks were taken at copy time (the window's decor at density 1). */
    private fun inFlight(baseline: DHashBaseline? = null, copied: Boolean = true): InFlightCapture {
        val masks = FrameMasks { WindowMaskResult(listOf(MaskRect(0.0, 0.0, 0.5, 0.5)), false, coverage, "sig") }
        if (copied) masks.masksFor(window)
        return InFlightCapture(
            requestId = "capture-7",
            requestGeometry = CaptureGeometry(540, 1200, 1.0f),
            masks = masks,
            offeredBaseline = baseline,
            frameWaitMicros = 10,
            startedNanos = 1_000_000L,
        )
    }

    private fun result(status: CaptureStatus, jpeg: ByteArray = ByteArray(0)) = CaptureResult(
        requestId = 1,
        status = status,
        jpeg = jpeg,
        width = 810,
        height = 1800,
        dHash = "0f0f",
        contentHash = "sha",
        timings = CaptureTimings(
            surfaceCopyMicros = 100,
            maskFillMicros = 5,
            dHashMicros = 6,
            jpegMicros = 300,
            sha256Micros = 7,
            maskComputeMicros = 20,
        ),
    )

    @Test
    fun okStoresTheJpegAndReportsTheCopyTimeFrame() {
        val answer = outcomes.answer(inFlight(), result(CaptureStatus.Ok, byteArrayOf(1, 2, 3))) as CaptureAnswer.Captured

        assertEquals(3, frames[answer.frame.handle]?.size)
        assertEquals(
            CapturedFrame(answer.frame.handle, 810, 1800, "sha", true, 3, 8_000, "0f0f", "sig", coverage),
            answer.frame,
        )
        assertEquals("the copy-time decor, not the request-time one", BoundaryRect(0.0, 0.0, 1080.0, 2400.0), answer.boundaryRect)
        assertEquals(CaptureTimingsMicros(frameWaitMicros = 10, readbackMicros = 100, maskMicros = 31, encodeMicros = 307), answer.timings)
    }

    @Test
    fun withoutACopyTheBoundaryIsTheRequestTimeOneAndTheFrameIsWhollyMasked() {
        val answer = outcomes.answer(inFlight(copied = false), result(CaptureStatus.Ok, byteArrayOf(1))) as CaptureAnswer.Captured

        assertEquals(BoundaryRect(0.0, 0.0, 540.0, 1200.0), answer.boundaryRect)
        assertEquals(MaskMode.WholeFrame, answer.frame.maskCoverage.mode)
    }

    @Test
    fun failuresAreMappedExplicitly() {
        val expected = mapOf(
            CaptureStatus.SecureWindow to CaptureFailure.SecureWindow,
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
