package com.tugboat.android.host

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class HostMessagesTest {
    private val at = HostTime(monoUs = 81_234_567, wallUs = 1_791_712_345_678_901)

    @Test
    fun stampAddsAtWithoutReencodingTheMessage() {
        val message = """{"type":"input.pointer","input":{"x":390.0,"y":1e2}}"""
        assertEquals(
            """{"at":{"monoUs":81234567,"wallUs":1791712345678901},"type":"input.pointer","input":{"x":390.0,"y":1e2}}""",
            HostMessages.stamped(message, at),
        )
    }

    @Test
    fun stampKeepsACallerSuppliedAt() {
        val message = """{"type":"input.pointer","at":{"monoUs":5},"input":{}}"""
        assertEquals(message, HostMessages.stamped(message, at))
    }

    @Test
    fun stampHandlesLeadingSpaceAndEmptyObjects() {
        assertEquals(
            """ {"at":{"monoUs":81234567,"wallUs":1791712345678901}}""",
            HostMessages.stamped(" {}", at),
        )
    }

    @Test
    fun stampLeavesNonObjectsForTheEngineToReject() {
        listOf("not json", "[1]", "{\"type\":").forEach { assertEquals(it, HostMessages.stamped(it, at)) }
    }

    @Test
    fun batchWrapsMessagesInOrder() {
        assertEquals(
            """{"type":"batch","messages":[{"type":"a"},{"type":"b"}]}""",
            HostMessages.batch(listOf("""{"type":"a"}""", """{"type":"b"}""")),
        )
    }

    @Test
    fun timerFiredCarriesTheTimerId() {
        val message = JSONObject(HostMessages.timerFired("flush\"1"))
        assertEquals("timer.fired", message.getString("type"))
        assertEquals("flush\"1", message.getJSONObject("input").getString("timerId"))
    }

    @Test
    fun transportResultEchoesTheRawRequestId() {
        assertEquals(
            """{"type":"transport.result","input":{"requestId":17,"outcome":"timeout"}}""",
            HostMessages.transportResult("17", TransportOutcome.Timeout),
        )
        assertEquals(
            """{"type":"transport.result","input":{"requestId":"r-1","outcome":"error"}}""",
            HostMessages.transportResult("\"r-1\"", TransportOutcome.Error),
        )
    }

    @Test
    fun transportResultQuotesTheBody() {
        val body = "{\"sessionId\":\"s\"}\n"
        val input = JSONObject(HostMessages.transportResult("\"r\"", TransportOutcome.Http(202, body)))
            .getJSONObject("input")
        assertEquals("http", input.getString("outcome"))
        assertEquals(202, input.getInt("status"))
        assertEquals(body, input.getString("body"))
    }
}
