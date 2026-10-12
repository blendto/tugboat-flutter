package com.tugboat.android.capture

import android.os.Looper
import android.view.Window
import com.tugboat.android.host.DHashBaseline
import com.tugboat.android.host.FrameHandleTable
import com.tugboat.android.views.mask.MaskCoverage
import com.tugboat.android.views.mask.MaskMode
import com.tugboat.android.toolkit.MaskCoverageReason
import com.tugboat.android.views.mask.MaskRect
import com.tugboat.android.views.mask.WindowMaskResult
import com.tugboat.capture.CaptureResult
import com.tugboat.capture.CaptureStatus
import com.tugboat.capture.MaskCoverageMode
import com.tugboat.capture.NormalizedMask
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

@RunWith(RobolectricTestRunner::class)
class CaptureCoordinatorTest {
    private val frames = FrameHandleTable()
    private val capturer = FakeWindowCapturer()
    private val answers = ArrayList<CaptureAnswer>()
    private var window: Window? = laidOutWindow()
    private var maskResult = masks(MaskRect(0.0, 0.1, 0.5, 0.2), signature = "s1")
    private var mainAccepts = true
    private val windowWaiters = ArrayList<() -> Unit>()

    private val coordinator = CaptureCoordinator(
        mainThread = { task -> if (mainAccepts) task.run(); mainAccepts },
        window = { window },
        awaitWindow = { _, onDone -> windowWaiters += onDone },
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
    fun masksAreTakenAtCopyTimeNotWhenTheRequestArrives() {
        coordinator.onCaptureRequest(captureRequest("capture-1"))
        assertTrue("no masks travel with the request", capturer.requests.single().masks.isEmpty())

        // The layout moved between the request and the copy.
        maskResult = masks(MaskRect(0.5, 0.6, 0.5, 0.2), signature = "moved")
        val snapshot = capturer.copy(capturer.requests.single().requestId)

        assertEquals(listOf(NormalizedMask(0.5, 0.6, 0.5, 0.2)), snapshot.masks)
        assertEquals("moved", snapshot.structureSignature)
        assertEquals(MaskCoverageMode.Precise, snapshot.coverage?.mode)
        capturer.calls.single().onComplete(ok(capturer.requests.single().requestId, byteArrayOf(1)))
        assertEquals("moved", (answers.single() as CaptureAnswer.Captured).frame.structureSignature)
    }

    @Test
    fun theRuntimeGetsScaleForceAndPixelSize() {
        coordinator.onCaptureRequest(captureRequest("capture-1", force = true, scale = 0.8))

        val sent = capturer.requests.single()
        assertTrue(sent.force)
        assertEquals("", sent.lastDHash)
        // 1080 px at density 1 (Robolectric mdpi) x 0.75 x 0.8.
        assertEquals(648, sent.pixelWidth)
        assertEquals(1440, sent.pixelHeight)
    }

    @Test
    fun theBaselineGoesToTheRuntimeWithItsStructureOnlyForUnforcedRequests() {
        val baseline = DHashBaseline("abcd", "s1")
        coordinator.onCaptureRequest(captureRequest("capture-1", force = false, baseline = baseline))
        coordinator.onCaptureRequest(captureRequest("capture-2", force = true, baseline = baseline))

        assertEquals(listOf("abcd", ""), capturer.requests.map { it.lastDHash })
        assertEquals(listOf("s1", ""), capturer.requests.map { it.lastStructureSignature })
    }

    @Test
    fun aDHashSkipIsReportedAsTheBaselineSoTheEngineCoalesces() {
        coordinator.onCaptureRequest(captureRequest("capture-1", force = false, baseline = DHashBaseline("abcd", "s1")))
        val id = capturer.requests.single().requestId

        capturer.complete(CaptureResult(requestId = id, status = CaptureStatus.SkippedByDHash, dHash = "abce", width = 10, height = 20))

        val frame = JSONObject(answers.single().toInputJson()).getJSONObject("frame")
        assertEquals("abcd", frame.getString("dHash"))
        assertEquals("s1", frame.getString("structureSignature"))
        assertEquals(0, frame.getInt("byteLength"))
    }

    @Test
    fun theInitialCaptureWaitsForAForegroundWindow() {
        window = null
        coordinator.onCaptureRequest(captureRequest("capture-1"))
        assertTrue("waits instead of failing", answers.isEmpty())

        window = laidOutWindow()
        windowWaiters.single()()
        assertEquals(1, capturer.requests.size)
    }

    @Test
    fun noWindowAfterTheWaitFailsAsBoundaryUnavailable() {
        window = null
        coordinator.onCaptureRequest(captureRequest("capture-1"))
        windowWaiters.single()()

        assertEquals(CaptureAnswer.Failed("capture-1", CaptureFailure.BoundaryUnavailable), answers.single())
        assertTrue(capturer.requests.isEmpty())
    }

    @Test
    fun aDecorNotYetLaidOutIsRetriedOnceAfterItsTraversal() {
        val decor = window!!.decorView
        decor.layout(0, 0, 0, 0)
        coordinator.onCaptureRequest(captureRequest("capture-1"))
        assertTrue("waits for layout instead of failing", answers.isEmpty())

        decor.layout(0, 0, 1080, 2400)
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(1, capturer.requests.size)

        decor.layout(0, 0, 0, 0)
        coordinator.onCaptureRequest(captureRequest("capture-2"))
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(CaptureAnswer.Failed("capture-2", CaptureFailure.LayoutUnavailable), answers.single())
    }

    @Test
    fun aMainThreadThatCannotTakeTheTaskStillAnswers() {
        mainAccepts = false
        coordinator.onCaptureRequest(captureRequest("capture-1"))

        assertEquals("capture-1", answers.single().requestId)
    }

    @Test
    fun aThrowingRuntimeAnswersFailedOnce() {
        capturer.throwOnCapture = IllegalStateException("boom")
        coordinator.onCaptureRequest(captureRequest("capture-1"))

        assertEquals(CaptureFailure.ReadbackFailed, (answers.single() as CaptureAnswer.Failed).failure)
        assertEquals(0, coordinator.pendingCount)
    }

    @Test
    fun aWholeFrameMaskIsStillCapturedMarkedMaskedAndReported() {
        maskResult = WindowMaskResult.wholeFrame(MaskCoverageReason.Animating)
        coordinator.onCaptureRequest(captureRequest("capture-1"))
        val id = capturer.requests.single().requestId

        val snapshot = capturer.copy(id)
        capturer.calls.single().onComplete(ok(id, byteArrayOf(9)))

        assertTrue(snapshot.wholeFrame)
        val frame = (answers.single() as CaptureAnswer.Captured).frame
        assertTrue(frame.masked)
        assertEquals(MaskCoverage(MaskMode.WholeFrame, setOf(MaskCoverageReason.Animating)), frame.maskCoverage)
    }

    @Test
    fun aCopyThatNeverTookMasksIsReportedAsWholeFrame() {
        coordinator.onCaptureRequest(captureRequest("capture-1"))
        val id = capturer.requests.single().requestId

        // The runtime completed without reaching the copy (no masks taken).
        capturer.calls.single().onComplete(CaptureResult(requestId = id, status = CaptureStatus.Ok, jpeg = byteArrayOf(1)))

        val frame = (answers.single() as CaptureAnswer.Captured).frame
        assertEquals(MaskMode.WholeFrame, frame.maskCoverage.mode)
    }

    @Test
    fun disposeDisposesTheRuntime() {
        coordinator.dispose()
        assertTrue(capturer.disposed)
    }

    private fun masks(rect: MaskRect, signature: String) =
        WindowMaskResult(listOf(rect), false, MaskCoverage(MaskMode.Precise), signature)

    private fun ok(id: Long, jpeg: ByteArray) =
        CaptureResult(requestId = id, status = CaptureStatus.Ok, jpeg = jpeg, width = 10, height = 20, dHash = "ff", contentHash = "c$id")
}
