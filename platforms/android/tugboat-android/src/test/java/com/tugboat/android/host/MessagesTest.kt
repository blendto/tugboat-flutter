package com.tugboat.android.host

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class MessagesTest {
    private val at = HostTime(monoUs = 81_234_567, wallUs = 1_791_712_345_678_901)

    @Test
    fun envelopeWrapsTheCallerInputVerbatim() {
        assertEquals(
            """{"type":"input.pointer","at":{"monoUs":81234567,"wallUs":1791712345678901},"input":{"x":390.0,"y":1e2}}""",
            EngineMessage("input.pointer", """{"x":390.0,"y":1e2}""", at).toJson(),
        )
    }

    @Test
    fun untimedEnvelopesHaveNoAt() {
        assertEquals(
            """{"type":"engine.configure","input":{}}""",
            EngineMessage("engine.configure", "{}", at = null).toJson(),
        )
    }

    @Test
    fun typesAreQuoted() {
        assertEquals("""{"type":"a\"b","input":{}}""", EngineMessage("a\"b", "{}", null).toJson())
    }

    @Test
    fun batchWrapsMessagesInOrder() {
        assertEquals(
            """{"type":"batch","messages":[{"type":"a","at":{"monoUs":81234567,"wallUs":1791712345678901},"input":{}},""" +
                """{"type":"b","input":{"k":1}}]}""",
            EngineMessage.batchJson(listOf(EngineMessage("a", "{}", at), EngineMessage("b", """{"k":1}""", null))),
        )
    }

    @Test
    fun timerFiredInputCarriesTheTimerId() {
        assertEquals("flush\"1", JSONObject(HostMessages.timerFiredInput("flush\"1")).getString("timerId"))
    }

    @Test
    fun transportResultInputs() {
        assertEquals(
            """{"requestId":"http-1","outcome":"timeout"}""",
            HostMessages.transportResultInput("http-1", TransportOutcome.Timeout),
        )
        assertEquals(
            """{"requestId":"http-2","outcome":"error"}""",
            HostMessages.transportResultInput("http-2", TransportOutcome.Error),
        )
        val body = "{\"sessionId\":\"s\"}\n"
        val http = JSONObject(HostMessages.transportResultInput("http-3", TransportOutcome.Http(202, body)))
        assertEquals("http", http.getString("outcome"))
        assertEquals(202, http.getInt("status"))
        assertEquals(body, http.getString("body"))
        val withRetry = JSONObject(
            HostMessages.transportResultInput(
                "http-4",
                TransportOutcome.Http(429, "", retryAfter = "30"),
            ),
        )
        assertEquals("30", withRetry.getString("retryAfter"))
    }
}
