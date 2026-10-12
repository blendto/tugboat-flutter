package com.tugboat.android.capture

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The `capture.result` inputs the host sends. The backend values are the
 * collector's closed enum: anything else 400s every frame upload.
 */
@RunWith(RobolectricTestRunner::class)
class CaptureResultJsonTest {
    @Test
    fun capturedCarriesTheNativeBackendForBothFields() {
        val answer = CaptureAnswer.Captured(
            requestId = "capture-1",
            frame = CapturedFrame("frame-1", 300, 600, "sha", true, 1234, 5000, "00ff", "sig"),
            boundaryRect = BoundaryRect(0.0, 0.0, 400.0, 800.0),
            timings = CaptureTimingsMicros(1, 2, 3, 4),
        )

        val json = JSONObject(answer.toInputJson())

        assertEquals("captured", json.getString("outcome"))
        val frame = json.getJSONObject("frame")
        assertEquals("nativeCpuExperimental", frame.getString("requestedBackend"))
        assertEquals("nativeCpuExperimental", frame.getString("resolvedBackend"))
        assertEquals(
            setOf(
                "handle", "width", "height", "contentHash", "masked", "byteLength", "captureMicros",
                "requestedBackend", "resolvedBackend", "dHash", "structureSignature",
            ),
            frame.keys().asSequence().toSet(),
        )
        assertEquals(400.0, json.getJSONObject("boundaryRect").getDouble("width"), 0.0)
        assertEquals(4, json.getJSONObject("timings").getLong("encodeMicros"))
        assertEquals(listOf("frame-1"), answer.frameHandles)
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
    fun failureNamesAreTheEnginesVocabulary() {
        assertEquals(
            listOf("boundaryUnavailable", "layoutUnavailable", "paintTimedOut", "readbackFailed", "maskFailed", "encodingFailed"),
            CaptureFailure.values().map { it.wire },
        )
    }

    @Test
    fun durationsAreClampedToTheEnginesBounds() {
        val answer = CaptureAnswer.Failed("capture-4", CaptureFailure.PaintTimedOut, CaptureTimingsMicros(frameWaitMicros = -5))
        assertEquals(0, JSONObject(answer.toInputJson()).getJSONObject("timings").getLong("frameWaitMicros"))
    }
}
