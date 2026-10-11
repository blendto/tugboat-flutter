package com.tugboat.android.host

import org.json.JSONException
import org.json.JSONTokener

/**
 * Splits JSON text into the exact source text of its members or elements,
 * without re-encoding anything. The host uses it where bytes must pass
 * through untouched: engine-built HTTP bodies (org.json would print `390.0`
 * as `390`), multipart field order, and adding `at` to a caller's message.
 *
 * Throws [JSONException] on input that is not the expected container.
 */
internal object RawJson {
    /** Members of a JSON object, in source order, as raw value text. */
    fun members(objectText: String): Map<String, String> {
        val cursor = Cursor(objectText)
        val members = LinkedHashMap<String, String>()
        cursor.open('{')
        if (!cursor.closes('}')) {
            do {
                val key = decodeString(cursor.string())
                cursor.expect(':')
                members[key] = cursor.value()
            } while (cursor.next('}'))
        }
        cursor.end()
        return members
    }

    /** Elements of a JSON array, in order, as raw value text. */
    fun elements(arrayText: String): List<String> {
        val cursor = Cursor(arrayText)
        val elements = ArrayList<String>()
        cursor.open('[')
        if (!cursor.closes(']')) {
            do {
                elements += cursor.value()
            } while (cursor.next(']'))
        }
        cursor.end()
        return elements
    }

    /** Decodes a raw JSON string token (with quotes) to its value. */
    fun decodeString(token: String): String =
        JSONTokener(token).nextValue() as? String ?: throw JSONException("expected string: $token")

    private class Cursor(private val text: String) {
        private var pos = 0

        fun open(bracket: Char) {
            skipSpace()
            expect(bracket)
        }

        /** Consumes [bracket] when the container is empty. */
        fun closes(bracket: Char): Boolean {
            skipSpace()
            if (pos < text.length && text[pos] == bracket) {
                pos++
                return true
            }
            return false
        }

        /** After a member: true on `,`, false after consuming [bracket]. */
        fun next(bracket: Char): Boolean {
            skipSpace()
            if (pos < text.length && text[pos] == ',') {
                pos++
                return true
            }
            expect(bracket)
            return false
        }

        fun expect(char: Char) {
            skipSpace()
            if (pos >= text.length || text[pos] != char) fail("expected '$char'")
            pos++
        }

        fun end() {
            skipSpace()
            if (pos != text.length) fail("trailing text")
        }

        fun string(): String {
            skipSpace()
            if (pos >= text.length || text[pos] != '"') fail("expected string")
            val start = pos
            skipString()
            return text.substring(start, pos)
        }

        fun value(): String {
            skipSpace()
            val start = pos
            when (text.getOrNull(pos)) {
                '"' -> skipString()
                '{', '[' -> skipContainer()
                null -> fail("expected value")
                else -> skipScalar()
            }
            return text.substring(start, pos)
        }

        private fun skipString() {
            pos++ // opening quote
            while (pos < text.length) {
                when (text[pos]) {
                    '\\' -> pos += 2
                    '"' -> {
                        pos++
                        return
                    }
                    else -> pos++
                }
            }
            fail("unterminated string")
        }

        private fun skipContainer() {
            var depth = 0
            do {
                when (text.getOrNull(pos)) {
                    null -> fail("unterminated container")
                    '"' -> {
                        skipString()
                        continue
                    }
                    '{', '[' -> depth++
                    '}', ']' -> depth--
                }
                pos++
            } while (depth > 0)
        }

        private fun skipScalar() {
            val start = pos
            while (pos < text.length && text[pos] !in SCALAR_END) pos++
            if (pos == start) fail("expected value")
        }

        private fun skipSpace() {
            while (pos < text.length && text[pos] in WHITESPACE) pos++
        }

        private fun fail(reason: String): Nothing = throw JSONException("$reason at $pos")
    }

    private const val WHITESPACE = " \t\r\n"
    private const val SCALAR_END = ",}] \t\r\n"
}
