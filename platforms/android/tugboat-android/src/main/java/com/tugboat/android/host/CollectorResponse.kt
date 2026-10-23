package com.tugboat.android.host

import android.util.Log
import java.nio.charset.StandardCharsets

/**
 * Turns a collector response into the `transport.result` outcome the engine
 * accepts. The engine rejects a `body` over 64 KiB or a `status` outside
 * 100–599 as `invalid_message`, and a rejected answer leaves its request
 * unanswered, which stalls every delivery lane. So neither may reach it.
 */
internal object CollectorResponse {
    /** `transport.result.body` carries at most this many UTF-8 bytes. */
    const val MAX_BODY_BYTES = 64 * 1024

    /** `transport.result.retryAfter` carries at most this many bytes. */
    const val MAX_RETRY_AFTER_BYTES = 128

    val VALID_STATUSES = 100..599

    /**
     * The `Retry-After` value to forward: trimmed of ASCII whitespace (as the engine trims), or null
     * when empty or longer than [MAX_RETRY_AFTER_BYTES] UTF-8 bytes.
     */
    fun forwardRetryAfter(raw: String?): String? {
        val trimmed = raw?.trim { it == ' ' || it in '\t'..'\r' }?.takeIf { it.isNotEmpty() } ?: return null
        return if (utf8Size(trimmed) <= MAX_RETRY_AFTER_BYTES) trimmed else null
    }

    private const val TAG = "TugboatHttp"

    /** [TransportOutcome.Http] for a status the engine accepts, otherwise [TransportOutcome.Error]. */
    fun outcome(status: Int, body: ByteArray, retryAfter: String? = null): TransportOutcome {
        if (status !in VALID_STATUSES) {
            Log.w(TAG, "collector answered with status $status; reporting a transport error")
            return TransportOutcome.Error
        }
        return TransportOutcome.Http(status, text(body), forwardRetryAfter(retryAfter))
    }

    /**
     * The body as text of at most [MAX_BODY_BYTES] UTF-8 bytes. The bytes are
     * cut back to a complete character before decoding, and invalid bytes,
     * which decode to U+FFFD and so can grow, are trimmed after.
     */
    fun text(body: ByteArray): String {
        val decoded = String(completePrefix(body), StandardCharsets.UTF_8)
        if (utf8Size(decoded) <= MAX_BODY_BYTES) return decoded
        var end = 0
        var size = 0
        while (end < decoded.length) {
            val codePoint = decoded.codePointAt(end)
            val width = utf8Width(codePoint)
            if (size + width > MAX_BODY_BYTES) break
            size += width
            end += Character.charCount(codePoint)
        }
        return decoded.substring(0, end)
    }

    /** At most [MAX_BODY_BYTES] bytes of [body], without a trailing partial UTF-8 sequence. */
    fun completePrefix(body: ByteArray): ByteArray {
        val bytes = if (body.size > MAX_BODY_BYTES) body.copyOf(MAX_BODY_BYTES) else body
        var lead = bytes.size - 1
        // A sequence is at most 4 bytes: look back over up to 3 continuation bytes.
        while (lead >= 0 && lead > bytes.size - 4 && (bytes[lead].toInt() and 0xC0) == 0x80) lead--
        if (lead < 0 || lead + sequenceLength(bytes[lead].toInt() and 0xFF) <= bytes.size) return bytes
        return bytes.copyOf(lead)
    }

    /** Length announced by a lead byte; 1 for ASCII and for invalid leads. */
    private fun sequenceLength(lead: Int): Int = when (lead) {
        in 0xF0..0xF7 -> 4
        in 0xE0..0xEF -> 3
        in 0xC0..0xDF -> 2
        else -> 1
    }

    private fun utf8Width(codePoint: Int): Int = when {
        codePoint < 0x80 -> 1
        codePoint < 0x800 -> 2
        codePoint < 0x10000 -> 3
        else -> 4
    }

    private fun utf8Size(text: String): Int {
        var size = 0
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            size += utf8Width(codePoint)
            index += Character.charCount(codePoint)
        }
        return size
    }
}
