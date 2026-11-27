package com.tugboat.android.okhttp

import com.tugboat.android.Tugboat
import com.tugboat.android.adapter.TugboatAdapters
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Section 4.5's byte-reading rules, as the engine input they produce. */
@RunWith(RobolectricTestRunner::class)
class ErrorBodiesTest {
    /** The `errorResponseBody` the encoder sends for these peeked bytes. */
    private fun sent(bytes: ByteArray, contentType: String?): String {
        val messages = ArrayList<String>()
        TugboatAdapters.tapEvidenceForTesting { _, input -> messages += input }.use {
            Tugboat.beginNetworkCall("GET", "/r").complete(statusCode = 500, errorResponseBody = ErrorBodies.classify(bytes, contentType))
        }
        val message = messages.single()
        val start = message.indexOf("\"errorResponseBody\":") + "\"errorResponseBody\":".length
        return message.substring(start, message.length - 1)
    }

    private fun sent(text: String, contentType: String?) = sent(text.toByteArray(Charsets.UTF_8), contentType)

    @Test
    fun jsonMediaTypesAreCaseInsensitiveWithoutParameters() {
        val json = listOf(
            "application/json",
            "Application/JSON",
            "application/json; charset=utf-8",
            "application/json;charset=UTF-8",
            "  application/json  ",
            "application/problem+json",
            "application/vnd.api+json; ext=bulk",
            "APPLICATION/LD+JSON",
            "text/x+json",
            // Dio's isJsonMimeType also takes text/json.
            "text/json",
            "Text/JSON; charset=utf-8",
        )
        json.forEach { assertTrue(it, ErrorBodies.isJson(it)) }
        val notJson = listOf(
            null,
            "",
            "text/plain",
            "text/jsonp",
            "text/json-seq",
            "application/jsonp",
            "application/json-patch",
            "application/x-json",
            "json",
            "/json",
            "application/",
            "application/json/extra",
            "application/xml; profile=+json",
        )
        notJson.forEach { assertFalse(it.toString(), ErrorBodies.isJson(it)) }
    }

    @Test
    fun aCompleteJsonBodyIsJsonTextAndAnythingElseText() {
        assertEquals("{\"jsonText\":\"{\\\"a\\\":1}\"}", sent("{\"a\":1}", "application/json"))
        assertEquals("{\"jsonText\":\"{\\\"a\\\":1}\"}", sent("{\"a\":1}", "text/json"))
        assertEquals("{\"value\":\"{\\\"a\\\":1}\"}", sent("{\"a\":1}", "text/plain"))
        assertEquals("{\"value\":\"{\\\"a\\\":1}\"}", sent("{\"a\":1}", null))
        // Empty: no body for JSON (the engine), an empty text body otherwise (Dio's "").
        assertEquals("{\"jsonText\":\"\"}", sent("", "application/json"))
        assertEquals("{\"value\":\"\"}", sent("", "text/html"))
    }

    @Test
    fun completenessIsAtMost65536PeekedBytes() {
        val exact = "\"" + "x".repeat(65_534) + "\""
        assertTrue(sent(exact, "application/json").startsWith("{\"jsonText\":"))
        val over = "\"" + "x".repeat(65_535) + "\""
        // Text from here on; the encoder then cuts any text body to 4097 units (also exact).
        assertEquals("{\"value\":\"\\\"${"x".repeat(4_096)}\"}", sent(over, "application/json"))
    }

    /**
     * The adapter keeps the whole characters of the first 4100 bytes; the
     * encoder then cuts any text body to 4097 UTF-16 units. Multi-byte text
     * shows the adapter's cut, which is the shorter one in units.
     */
    @Test
    fun aTextBodyKeepsTheWholeCharactersOfTheFirst4100Bytes() {
        val euro = "\u20AC"
        // 1366 x 3 = 4098 bytes; a 1367th would end at byte 4101.
        assertEquals("{\"value\":\"${euro.repeat(1_366)}\"}", sent(euro.repeat(2_000), "text/plain"))
        assertEquals("{\"value\":\"aa${euro.repeat(1_366)}\"}", sent("aa" + euro.repeat(2_000), "text/plain"))
        assertEquals("{\"value\":\"aaa${euro.repeat(1_365)}\"}", sent("aaa" + euro.repeat(2_000), "text/plain"))
        // A pair is never split: 1 + 1024 x 4 = 4097 bytes, and a 1025th pair would end at byte 4101.
        val grin = "\uD83D\uDE00"
        assertEquals("{\"value\":\"${grin.repeat(1_025)}\"}", sent(grin.repeat(1_100), "text/plain"))
        assertEquals("{\"value\":\"a${grin.repeat(1_024)}\"}", sent("a" + grin.repeat(1_100), "text/plain"))
        // ASCII: the encoder's 4097 units are the shorter cut.
        assertEquals("{\"value\":\"${"a".repeat(4_097)}\"}", sent("a".repeat(10_000), "text/plain"))
    }

    @Test
    fun malformedBytesAreReplacedByMaximalSubpart() {
        val bytes = byteArrayOf(0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xED.toByte(), 0xA0.toByte(), 0x80.toByte(), 0x22, 0x7D)
        assertEquals("{\"jsonText\":\"{\\\"a\\\":\\\"\uFFFD\uFFFD\uFFFD\\\"}\"}", sent(bytes, "application/json"))
        assertEquals("{\"value\":\"x\uFFFD\"}", sent(byteArrayOf(0x78, 0xFF.toByte()), "text/plain"))
    }
}
