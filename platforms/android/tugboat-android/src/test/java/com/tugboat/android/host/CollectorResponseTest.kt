package com.tugboat.android.host

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Every outcome must be one the engine's `transport.result` accepts: a body
 * of at most 64 KiB of UTF-8 and a status in 100–599.
 */
class CollectorResponseTest {
    private val limit = CollectorResponse.MAX_BODY_BYTES

    private fun ascii(count: Int) = "a".repeat(count)

    private fun text(value: String) = CollectorResponse.text(value.toByteArray(Charsets.UTF_8))

    @Test
    fun shortBodiesPassThrough() {
        assertEquals("{\"sessionId\":\"s-1\"} é😀", text("{\"sessionId\":\"s-1\"} é😀"))
        assertEquals("", CollectorResponse.text(ByteArray(0)))
    }

    @Test
    fun aFourByteCharacterStraddlingTheCutIsDropped() {
        for (kept in 1..3) {
            val prefix = ascii(limit - kept)
            val result = text(prefix + "😀tail")
            assertEquals("$kept byte(s) of the character inside the limit", prefix, result)
            assertFalse(result.contains('�'))
        }
    }

    @Test
    fun shorterCharactersStraddlingTheCutAreDropped() {
        assertEquals(ascii(limit - 1), text(ascii(limit - 1) + "é"))
        assertEquals(ascii(limit - 2), text(ascii(limit - 2) + "€"))
        assertEquals(ascii(limit - 1), text(ascii(limit - 1) + "€"))
    }

    @Test
    fun aCharacterEndingExactlyAtTheLimitIsKept() {
        val body = ascii(limit - 4) + "😀"
        assertEquals(body, text(body + "more"))
        assertEquals(limit, text(ascii(limit + 10)).length)
    }

    @Test
    fun invalidBytesNeverGrowPastTheLimit() {
        val result = CollectorResponse.text(ByteArray(limit + 100) { 0xFF.toByte() })
        assertTrue(result.toByteArray(Charsets.UTF_8).size <= limit)
        assertTrue(result.isNotEmpty())
    }

    @Test
    fun statusesOutsideTheEngineRangeAreErrors() {
        for (status in listOf(-1, 0, 99, 600, 1_000)) {
            assertEquals("$status", TransportOutcome.Error, CollectorResponse.outcome(status, "x".toByteArray()))
        }
        for (status in listOf(100, 202, 400, 599)) {
            assertEquals("$status", TransportOutcome.Http(status, "x"), CollectorResponse.outcome(status, "x".toByteArray()))
        }
    }
}
