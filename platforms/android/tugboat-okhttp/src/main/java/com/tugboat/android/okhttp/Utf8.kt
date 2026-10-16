package com.tugboat.android.okhttp

/**
 * UTF-8 decoding that replaces each maximal subpart of an ill-formed
 * sequence with one U+FFFD (Unicode 15, section 3.9, "U+FFFD Substitution of
 * Maximal Subparts"), as Dart's `utf8.decode(allowMalformed: true)` and
 * Swift's `String(decoding:as:)` do (evidence-messages.md section 4.5).
 *
 * Written out because the JVM's `CodingErrorAction.REPLACE` decoder gives
 * one U+FFFD for an encoded surrogate (`ED A0 80`) where the practice gives
 * three, and Android's decoder is not verified.
 */
internal object Utf8 {
    private const val REPLACEMENT = '�'

    /**
     * Decodes the first [length] bytes of [bytes]. When [maxUtf8Bytes] is
     * set, stops before the first character whose UTF-8 encoding would pass
     * it (a U+FFFD counts 3), so the result is whole characters of the full
     * decoding.
     */
    fun decode(bytes: ByteArray, length: Int = bytes.size, maxUtf8Bytes: Int = Int.MAX_VALUE): String {
        val out = StringBuilder(minOf(length, maxUtf8Bytes))
        var written = 0
        var i = 0
        while (i < length) {
            val lead = bytes[i].toInt() and 0xFF
            val sequence = if (lead < 0x80) 1 else wellFormedPrefix(bytes, i, length, lead)
            val complete = sequence > 0
            val consumed = if (complete) sequence else -sequence
            val codePoint = if (complete) codePoint(bytes, i, sequence) else REPLACEMENT.code
            val size = utf8Size(codePoint)
            if (written + size > maxUtf8Bytes) break
            out.appendCodePoint(codePoint)
            written += size
            i += consumed
        }
        return out.toString()
    }

    /**
     * The length of the well-formed sequence at [start] (positive), or minus
     * the length of its maximal subpart (at least one byte) when it is
     * ill-formed: the bytes that start a well-formed sequence before the
     * first byte that cannot continue it.
     */
    private fun wellFormedPrefix(bytes: ByteArray, start: Int, length: Int, lead: Int): Int {
        val expected = when (lead) {
            in 0xC2..0xDF -> 2
            in 0xE0..0xEF -> 3
            in 0xF0..0xF4 -> 4
            else -> return -1 // 80..C1, F5..FF never start a sequence
        }
        // The second byte's range is narrower after some leads (Unicode Table 3-7).
        val secondLow = when (lead) {
            0xE0 -> 0xA0
            0xF0 -> 0x90
            else -> 0x80
        }
        val secondHigh = when (lead) {
            0xED -> 0x9F
            0xF4 -> 0x8F
            else -> 0xBF
        }
        for (k in 1 until expected) {
            if (start + k >= length) return -k
            val b = bytes[start + k].toInt() and 0xFF
            val inRange = if (k == 1) b in secondLow..secondHigh else b in 0x80..0xBF
            if (!inRange) return -k
        }
        return expected
    }

    private fun codePoint(bytes: ByteArray, start: Int, sequence: Int): Int {
        val lead = bytes[start].toInt() and 0xFF
        var value = when (sequence) {
            1 -> return lead
            2 -> lead and 0x1F
            3 -> lead and 0x0F
            else -> lead and 0x07
        }
        for (k in 1 until sequence) value = (value shl 6) or (bytes[start + k].toInt() and 0x3F)
        return value
    }

    fun utf8Size(codePoint: Int) = when {
        codePoint < 0x80 -> 1
        codePoint < 0x800 -> 2
        codePoint < 0x10000 -> 3
        else -> 4
    }
}
