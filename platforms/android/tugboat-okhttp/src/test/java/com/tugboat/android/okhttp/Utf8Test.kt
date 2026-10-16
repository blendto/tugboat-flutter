package com.tugboat.android.okhttp

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Maximal-subpart U+FFFD replacement: the examples of Unicode 15 section 3.9
 * (Tables 3-8 to 3-11) and the boundaries of Table 3-7.
 */
class Utf8Test {
    private fun decode(vararg bytes: Int, maxUtf8Bytes: Int = Int.MAX_VALUE) =
        Utf8.decode(ByteArray(bytes.size) { bytes[it].toByte() }, maxUtf8Bytes = maxUtf8Bytes)

    private fun fffd(count: Int) = "\uFFFD".repeat(count)

    @Test
    fun wellFormedSequencesDecode() {
        assertEquals("a", decode(0x61))
        assertEquals("\u0080", decode(0xC2, 0x80))
        assertEquals("\u07FF", decode(0xDF, 0xBF))
        assertEquals("\u0800", decode(0xE0, 0xA0, 0x80))
        assertEquals("\u20AC", decode(0xE2, 0x82, 0xAC))
        assertEquals("\uD7FF", decode(0xED, 0x9F, 0xBF))
        assertEquals("\uE000", decode(0xEE, 0x80, 0x80))
        assertEquals("\uFFFF", decode(0xEF, 0xBF, 0xBF))
        assertEquals("\uD800\uDC00", decode(0xF0, 0x90, 0x80, 0x80))
        assertEquals("\uD83D\uDE00", decode(0xF0, 0x9F, 0x98, 0x80))
        assertEquals("\uDBFF\uDFFF", decode(0xF4, 0x8F, 0xBF, 0xBF))
        assertEquals("", decode())
    }

    @Test
    fun table3_8MaximalSubparts() {
        // 61 F1 80 80 E1 80 C2 62 80 63 80 BF 64
        assertEquals(
            "a${fffd(3)}b${fffd(1)}c${fffd(2)}d",
            decode(0x61, 0xF1, 0x80, 0x80, 0xE1, 0x80, 0xC2, 0x62, 0x80, 0x63, 0x80, 0xBF, 0x64),
        )
    }

    @Test
    fun table3_9NonShortestForms() {
        assertEquals("${fffd(8)}A", decode(0xC0, 0xAF, 0xE0, 0x80, 0xBF, 0xF0, 0x81, 0x82, 0x41))
    }

    @Test
    fun table3_10EncodedSurrogatesAreThreeReplacementsEach() {
        assertEquals(fffd(3), decode(0xED, 0xA0, 0x80))
        assertEquals(fffd(3), decode(0xED, 0xBF, 0xBF))
        assertEquals("${fffd(8)}A", decode(0xED, 0xA0, 0x80, 0xED, 0xBF, 0xBF, 0xED, 0xAF, 0x41))
        // A surrogate pair encoded as two 3-byte sequences (CESU-8): six.
        assertEquals(fffd(6), decode(0xED, 0xA0, 0xBD, 0xED, 0xB8, 0x80))
    }

    @Test
    fun table3_11OtherIllFormedSequences() {
        assertEquals("${fffd(5)}A${fffd(2)}B", decode(0xF4, 0x91, 0x92, 0x93, 0xFF, 0x41, 0x80, 0xBF, 0x42))
        assertEquals(fffd(1), decode(0xF5))
        assertEquals(fffd(4), decode(0xF8, 0x88, 0x80, 0x80))
    }

    @Test
    fun table3_12TruncatedSequences() {
        assertEquals("${fffd(4)}A", decode(0xE1, 0x80, 0xE2, 0xF0, 0x91, 0x92, 0xF1, 0xBF, 0x41))
        assertEquals("a${fffd(1)}", decode(0x61, 0xE2, 0x82))
        assertEquals(fffd(1), decode(0xF0, 0x9F, 0x98))
        assertEquals(fffd(1), decode(0xC2))
    }

    @Test
    fun theSecondByteRangeFollowsTheLead() {
        // E0 needs A0..BF; ED 80..9F; F0 90..BF; F4 80..8F.
        assertEquals(fffd(3), decode(0xE0, 0x9F, 0x80))
        assertEquals(fffd(2), decode(0xED, 0xA0))
        assertEquals(fffd(4), decode(0xF0, 0x8F, 0x80, 0x80))
        assertEquals(fffd(4), decode(0xF4, 0x90, 0x80, 0x80))
        // A lead followed by a byte that starts its own sequence keeps it.
        assertEquals("${fffd(1)}\u20AC", decode(0xE2, 0xE2, 0x82, 0xAC))
    }

    @Test
    fun aByteLimitKeepsOnlyWholeCharacters() {
        assertEquals("ab", decode(0x61, 0x62, 0x63, maxUtf8Bytes = 2))
        // A 3-byte character that would pass the limit is left out.
        assertEquals("a", decode(0x61, 0xE2, 0x82, 0xAC, maxUtf8Bytes = 3))
        assertEquals("a\u20AC", decode(0x61, 0xE2, 0x82, 0xAC, maxUtf8Bytes = 4))
        // A replacement counts its 3 UTF-8 bytes, not the 1 byte it replaces.
        assertEquals("a", decode(0x61, 0xFF, maxUtf8Bytes = 3))
        assertEquals("a\uFFFD", decode(0x61, 0xFF, maxUtf8Bytes = 4))
        // A pair is never split.
        assertEquals("", decode(0xF0, 0x9F, 0x98, 0x80, maxUtf8Bytes = 3))
    }
}
