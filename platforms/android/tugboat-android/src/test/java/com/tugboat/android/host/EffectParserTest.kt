package com.tugboat.android.host

import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class EffectParserTest {
    @Test
    fun parsesEveryKnownEffectInOrder() {
        val effects = EffectParser.parse(
            response(
                """{"type":"timer.schedule","timerId":"flush","atMonoUs":4000000}""",
                """{"type":"frame.release","handle":"frame-1"}""",
                """{"type":"timer.cancel","timerId":"flush"}""",
            ),
        )
        assertEquals(
            listOf(
                Effect.TimerSchedule("flush", 4_000_000),
                Effect.FrameRelease("frame-1"),
                Effect.TimerCancel("flush"),
            ),
            effects,
        )
    }

    @Test
    fun jsonBodyIsKeptByteForByte() {
        val body = """{"events":[{"screenWidth":390.0,"n":1e21,"s":"a\/b"}]}"""
        val effect = EffectParser.parse(
            response("""{"type":"http.send","requestId":"r-7","lane":"events","path":"/v1/events/batch","timeoutMs":15000,"json":$body}"""),
        ).single()

        assertEquals(
            Effect.HttpSend(HttpRequest("\"r-7\"", "events", "/v1/events/batch", 15_000, HttpBody.Json(body))),
            effect,
        )
    }

    @Test
    fun multipartKeepsFieldOrderAndFrames() {
        val effect = EffectParser.parse(
            response(
                """{"type":"http.send","requestId":3,"lane":"frames","path":"/v1/frames","timeoutMs":15000,""" +
                    """"multipart":{"fields":{"sessionId":"s-1","frameNos":"1,2","frameMetadata":[{"frameNo":1}]},""" +
                    """"frames":[{"handle":"frame-1","filename":"1.jpg"},{"handle":"frame-2","filename":"2.jpg"}]}}""",
            ),
        ).single() as Effect.HttpSend

        assertEquals("3", effect.request.requestIdJson)
        assertEquals(
            HttpBody.Multipart(
                fields = listOf("sessionId" to "s-1", "frameNos" to "1,2", "frameMetadata" to "[{\"frameNo\":1}]"),
                frames = listOf(FramePart("frame-1", "1.jpg"), FramePart("frame-2", "2.jpg")),
            ),
            effect.request.body,
        )
    }

    @Test
    fun unknownTypesAreKeptForTheDispatcher() {
        assertEquals(
            listOf(Effect.Unknown("capture.request")),
            EffectParser.parse(response("""{"type":"capture.request","requestId":"c"}""")),
        )
    }

    @Test
    fun malformedEffectsAreSkipped() {
        val effects = EffectParser.parse(
            response(
                """{"type":"timer.schedule","timerId":"t"}""",
                """{"type":"http.send","requestId":"r","lane":"events","path":"/p","timeoutMs":1}""",
                """{"noType":true}""",
                """{"type":"timer.cancel","timerId":"t"}""",
            ),
        )
        assertEquals(listOf(Effect.TimerCancel("t")), effects)
    }

    @Test
    fun responsesWithoutEffectsHaveNone() {
        assertEquals(emptyList<Effect>(), EffectParser.parse("""{"type":"fingerprint.labelHash","result":{"hash":"x"}}"""))
    }

    private fun response(vararg effects: String) =
        """{"type":"t","records":[],"effects":[${effects.joinToString(",")}]}"""
}
