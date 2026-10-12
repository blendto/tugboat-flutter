package com.tugboat.android.host

import org.json.JSONException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
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
    fun jsonBodyIsThePreEncodedString() {
        val effect = EffectParser.parse(
            response(
                """{"type":"http.send","requestId":"http-7","lane":"events","path":"/v1/events/batch",""" +
                    """"timeoutMs":15000,"jsonBody":"{\"events\":[{\"w\":390.0}]}"}""",
            ),
        ).single()

        assertEquals(
            Effect.HttpSend(
                HttpRequest("http-7", "events", "/v1/events/batch", 15_000, HttpBody.Json("""{"events":[{"w":390.0}]}""")),
            ),
            effect,
        )
    }

    @Test
    fun multipartKeepsFieldPairOrderAndFrames() {
        val effect = EffectParser.parse(
            response(
                """{"type":"http.send","requestId":"http-3","lane":"frames","path":"/v1/frames","timeoutMs":15000,""" +
                    """"multipart":{"fields":[["sessionId","s-1"],["frameNos","1,2"],["frameMetadata","[{\"frameNo\":1}]"]],""" +
                    """"frames":[{"handle":"frame-1","filename":"1.jpg"},{"handle":"frame-2","filename":"2.jpg"}]}}""",
            ),
        ).single() as Effect.HttpSend

        assertEquals("http-3", effect.request.requestId)
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
                """{"type":"http.send","requestId":"r","lane":"frames","path":"/p","timeoutMs":1,""" +
                    """"multipart":{"fields":[["only-a-name"]],"frames":[]}}""",
                """{"noType":true}""",
                "17",
                """{"type":"timer.cancel","timerId":"t"}""",
            ),
        )
        assertEquals(listOf(Effect.TimerCancel("t")), effects)
    }

    @Test
    fun responsesWithoutEffectsHaveNone() {
        assertEquals(emptyList<Effect>(), EffectParser.parse("""{"type":"fingerprint.labelHash","result":{"hash":"x"}}"""))
    }

    @Test
    fun nonObjectResponsesThrow() {
        assertThrows(JSONException::class.java) { EffectParser.parse("not json") }
    }

    private fun response(vararg effects: String) =
        """{"type":"t","records":[],"effects":[${effects.joinToString(",")}]}"""
}
