package com.tugboat.android.capture

import android.view.Window
import com.tugboat.android.host.DHashBaseline
import com.tugboat.android.host.FrameHandleTable
import com.tugboat.android.views.mask.MaskRect
import com.tugboat.android.views.mask.WindowMaskResult
import com.tugboat.capture.CaptureResult
import com.tugboat.capture.CaptureStatus
import com.tugboat.capture.NormalizedMask
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class CaptureCoordinatorTest {
    private val frames = FrameHandleTable()
    private val capturer = FakeWindowCapturer()
    private val answers = ArrayList<CaptureAnswer>()
    private var window: Window? = laidOutWindow()
    private var maskResult = WindowMaskResult(listOf(MaskRect(0.0, 0.1, 0.5, 0.2)), failClosed = false)
    private var mainAccepts = true

    private val coordinator = CaptureCoordinator(
        mainThread = { task -> if (mainAccepts) task.run(); mainAccepts },
        window = { window },
        masks = { maskResult },
        capturer = capturer,
        frames = frames,
        answer = { answers += it },
    )

    @Test
    fun twoOutstandingRequestsAreEachAnsweredByIdInCompletionOrder() {
        coordinator.onCaptureRequest(captureRequest("capture-1"))
        coordinator.onCaptureRequest(captureRequest("capture-2"))
        assertEquals("both are with the runtime at once", 2, coordinator.pendingCount)
        val (first, second) = capturer.requests

        capturer.complete(ok(second.requestId, byteArrayOf(2, 2)))
        capturer.complete(ok(first.requestId, byteArrayOf(1)))

        assertEquals(listOf("capture-2", "capture-1"), answers.map { it.requestId })
        val handles = answers.map { (it as CaptureAnswer.Captured).frame.handle }
        assertArrayEquals(byteArrayOf(2, 2), frames[handles[0]])
        assertArrayEquals(byteArrayOf(1), frames[handles[1]])
        assertEquals(0, coordinator.pendingCount)
    }

    @Test
    fun aRepeatedRuntimeCallbackIsAnsweredOnce() {
        coordinator.onCaptureRequest(captureRequest("capture-1"))
        val id = capturer.requests.single().requestId
        capturer.complete(ok(id, byteArrayOf(1)))
        capturer.complete(ok(id, byteArrayOf(1)))

        assertEquals(1, answers.size)
    }

    @Test
    fun theRuntimeGetsMasksScaleAndForce() {
        coordinator.onCaptureRequest(captureRequest("capture-1", force = true, scale = 0.8))

        val sent = capturer.requests.single()
        assertEquals(listOf(NormalizedMask(0.0, 0.1, 0.5, 0.2)), sent.masks)
        assertTrue(sent.force)
        assertEquals("", sent.lastDHash)
        // 1080 px at density 1 (Robolectric mdpi) x 0.75 x 0.8.
        assertEquals(648, sent.pixelWidth)
        assertEquals(1440, sent.pixelHeight)
    }

    @Test
    fun theBaselineIsOfferedOnlyWhenTheStructureMatches() {
        val geometry = CaptureGeometry.of(window!!.peekDecorView())!!
        val same = StructureSignature.of(geometry, maskResult)
        coordinator.onCaptureRequest(captureRequest("capture-1", force = false, baseline = DHashBaseline("abcd", same)))
        coordinator.onCaptureRequest(captureRequest("capture-2", force = false, baseline = DHashBaseline("abcd", "other")))

        assertEquals(listOf("abcd", ""), capturer.requests.map { it.lastDHash })
    }

    @Test
    fun aDHashSkipIsReportedAsTheBaselineSoTheEngineCoalesces() {
        val geometry = CaptureGeometry.of(window!!.peekDecorView())!!
        val signature = StructureSignature.of(geometry, maskResult)
        coordinator.onCaptureRequest(captureRequest("capture-1", force = false, baseline = DHashBaseline("abcd", signature)))
        val id = capturer.requests.single().requestId

        capturer.complete(CaptureResult(requestId = id, status = CaptureStatus.SkippedByDHash, dHash = "abce", width = 10, height = 20))

        val frame = JSONObject(answers.single().toInputJson()).getJSONObject("frame")
        assertEquals("abcd", frame.getString("dHash"))
        assertEquals(signature, frame.getString("structureSignature"))
        assertEquals(0, frame.getInt("byteLength"))
    }

    @Test
    fun noForegroundWindowFailsAsBoundaryUnavailable() {
        window = null
        coordinator.onCaptureRequest(captureRequest("capture-1"))

        assertEquals(CaptureAnswer.Failed("capture-1", CaptureFailure.BoundaryUnavailable), answers.single())
        assertTrue(capturer.requests.isEmpty())
    }

    @Test
    fun aMainThreadThatCannotTakeTheTaskStillAnswers() {
        mainAccepts = false
        coordinator.onCaptureRequest(captureRequest("capture-1"))

        assertEquals("capture-1", answers.single().requestId)
    }

    @Test
    fun aThrowingRuntimeOrMaskPathAnswersFailedOnce() {
        capturer.throwOnCapture = IllegalStateException("boom")
        coordinator.onCaptureRequest(captureRequest("capture-1"))
        assertEquals(CaptureFailure.ReadbackFailed, (answers.single() as CaptureAnswer.Failed).failure)
        assertEquals(0, coordinator.pendingCount)

        val throwingMasks = CaptureCoordinator(
            mainThread = { it.run(); true },
            window = { window },
            masks = { throw IllegalStateException("walk") },
            capturer = capturer,
            frames = frames,
            answer = { answers += it },
        )
        throwingMasks.onCaptureRequest(captureRequest("capture-2"))
        assertEquals(CaptureFailure.MaskFailed, (answers.last() as CaptureAnswer.Failed).failure)
        assertEquals(2, answers.size)
    }

    @Test
    fun aFullFrameMaskIsStillCapturedAndMarkedMasked() {
        maskResult = WindowMaskResult(listOf(MaskRect.FULL_FRAME), failClosed = true)
        coordinator.onCaptureRequest(captureRequest("capture-1"))
        capturer.complete(ok(capturer.requests.single().requestId, byteArrayOf(9)))

        assertEquals(listOf(NormalizedMask(0.0, 0.0, 1.0, 1.0)), capturer.requests.single().masks)
        assertTrue((answers.single() as CaptureAnswer.Captured).frame.masked)
    }

    @Test
    fun disposeDisposesTheRuntime() {
        coordinator.dispose()
        assertTrue(capturer.disposed)
    }

    private fun ok(id: Long, jpeg: ByteArray) =
        CaptureResult(requestId = id, status = CaptureStatus.Ok, jpeg = jpeg, width = 10, height = 20, dHash = "ff", contentHash = "c$id")
}
