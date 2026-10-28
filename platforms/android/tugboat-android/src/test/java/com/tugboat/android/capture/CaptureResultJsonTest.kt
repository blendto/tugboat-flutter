package com.tugboat.android.capture

import com.tugboat.android.views.mask.MaskCoverage
import com.tugboat.android.views.mask.MaskMode
import com.tugboat.android.toolkit.MaskCoverageReason
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The `capture.result` inputs the host sends. The backend values are the
 * collector's closed enum: anything else 400s every frame upload.
 */
@RunWith(RobolectricTestRunner::class)
class CaptureResultJsonTest {
    private val answer = CaptureAnswer.Captured(
        requestId = "capture-1",
        frame = CapturedFrame(
            "frame-1", 300, 600, "sha", true, 1234, 5000, "00ff", "sig",
            MaskCoverage(MaskMode.WholeHost, setOf(MaskCoverageReason.ComposeDefault, MaskCoverageReason.WebView)),
            hasRegionHosts = true,
        ),
        boundaryRect = BoundaryRect(0.0, 0.0, 400.0, 800.0),
        timings = CaptureTimingsMicros(1, 2, 3, 4),
    )

    @Test
    fun capturedCarriesTheNativeBackendForBothFields() {
        val json = JSONObject(answer.toInputJson())

        assertEquals("captured", json.getString("outcome"))
        val frame = json.getJSONObject("frame")
        assertEquals("androidPixelCopy", frame.getString("requestedBackend"))
        assertEquals("androidPixelCopy", frame.getString("resolvedBackend"))
        assertEquals(
            setOf(
                "handle", "width", "height", "contentHash", "masked", "byteLength", "captureMicros",
                "requestedBackend", "resolvedBackend", "dHash", "structureSignature", "maskCoverage",
            ),
            frame.keys().asSequence().toSet(),
        )
        assertEquals(400.0, json.getJSONObject("boundaryRect").getDouble("width"), 0.0)
        assertEquals(4, json.getJSONObject("timings").getLong("encodeMicros"))
        assertEquals(listOf("frame-1"), answer.frameHandles)
    }

    @Test
    fun maskCoverageIsEncodedInTheEnginesShape() {
        val frame = JSONObject(answer.toInputJson()).getJSONObject("frame")

        assertEquals(
            """{"mode":"wholeHost","reasons":["composeDefault","webView"]}""",
            frame.getJSONObject("maskCoverage").toString(),
        )
    }

    @Test
    fun failedAndCancelledCarryNoFrame() {
        val failed = JSONObject(CaptureAnswer.Failed("capture-2", CaptureFailure.ReadbackFailed).toInputJson())
        assertEquals("failed", failed.getString("outcome"))
        assertEquals("readbackFailed", failed.getString("failure"))
        assertFalse(failed.has("frame"))

        val cancelled = JSONObject(CaptureAnswer.Cancelled("capture-3").toInputJson())
        assertEquals(setOf("requestId", "outcome"), cancelled.keys().asSequence().toSet())
        assertEquals("cancelled", cancelled.getString("outcome"))
    }

    @Test
    fun failureAndCoverageNamesAreTheEnginesVocabulary() {
        assertEquals(
            listOf(
                "boundaryUnavailable", "layoutUnavailable", "paintTimedOut", "readbackFailed", "maskFailed",
                "encodingFailed", "secureWindow",
            ),
            CaptureFailure.values().map { it.wire },
        )
        assertEquals(listOf("precise", "wholeHost", "wholeFrame"), MaskMode.values().map { it.wire })
        assertTrue(
            "every reason is in the engine's closed maskCoverage.reasons set",
            ENGINE_MASK_REASONS.containsAll(MaskCoverageReason.values().map { it.wire }),
        )
    }

    @Test
    fun durationsAreClampedToTheEnginesBounds() {
        val failed = CaptureAnswer.Failed("capture-4", CaptureFailure.PaintTimedOut, CaptureTimingsMicros(frameWaitMicros = -5))
        assertEquals(0, JSONObject(failed.toInputJson()).getJSONObject("timings").getLong("frameWaitMicros"))
    }

    private companion object {
        /** The engine's closed `maskCoverage.reasons` names (`core/session-engine`, PR #96). */
        val ENGINE_MASK_REASONS = setOf(
            "composeDefault", "composeVersionUnverified", "composeOwnerUnavailable", "interop", "animating",
            "unverifiedLayerAllowlist", "walkExhausted", "noWindowSize", "noDecor", "representable", "webView",
            "surfaceLayer", "unclassifiedLayer", "secureText", "overlayWindow", "regionUnreadable", "treeUnreadable",
            "renderer",
        )
    }
}
