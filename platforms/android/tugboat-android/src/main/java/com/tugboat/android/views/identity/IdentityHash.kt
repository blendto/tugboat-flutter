package com.tugboat.android.views.identity

import java.io.ByteArrayOutputStream
import java.security.MessageDigest

/**
 * The engine's `fingerprint.identityParts` hash (fingerprint schema v6),
 * computed in Kotlin because the engine thread is not synchronous with the
 * main thread. Verified against every
 * `conformance/fingerprint/identity_parts` vector.
 *
 * Parts are sorted by key comparing UTF-16 code units (Kotlin and Dart
 * `String.compareTo` agree), written `key=value`, and joined with `|` without
 * escaping. The fingerprint is the first 16 lowercase hex characters of
 * SHA-256 over the UTF-8 bytes, or `""` for no parts.
 */
internal object IdentityHash {
    const val FINGERPRINT_SCHEMA_VERSION = 6
    private const val HEX_LENGTH = 16

    fun canonicalString(parts: Map<String, String>): String =
        parts.entries.sortedWith { a, b -> a.key.compareTo(b.key) }
            .joinToString(separator = "|") { "${it.key}=${it.value}" }

    fun fingerprint(parts: Map<String, String>): String {
        if (parts.isEmpty()) return ""
        return labelHash(canonicalString(parts))
    }

    /** Dart `tugboatLabelHash` over the UTF-8 bytes of [value]. */
    fun labelHash(value: String): String {
        if (value.isEmpty()) return ""
        val digest = MessageDigest.getInstance("SHA-256").digest(utf8(value))
        return digest.joinToString(separator = "") { "%02x".format(it.toInt() and 0xff) }.take(HEX_LENGTH)
    }

    /** Dart `utf8.encode`: a lone surrogate becomes U+FFFD. */
    internal fun utf8(text: String): ByteArray {
        val out = ByteArrayOutputStream(text.length)
        var i = 0
        while (i < text.length) {
            val codePoint = codePointAt(text, i)
            i += if (codePoint > Char.MAX_VALUE.code) 2 else 1
            writeUtf8(out, codePoint)
        }
        return out.toByteArray()
    }

    private fun codePointAt(text: String, i: Int): Int {
        val c = text[i]
        if (c.isHighSurrogate() && i + 1 < text.length && text[i + 1].isLowSurrogate()) {
            return Character.toCodePoint(c, text[i + 1])
        }
        return if (c.isSurrogate()) REPLACEMENT else c.code
    }

    private fun writeUtf8(out: ByteArrayOutputStream, cp: Int) {
        when {
            cp < 0x80 -> out.write(cp)
            cp < 0x800 -> {
                out.write(0xC0 or (cp shr 6))
                out.write(0x80 or (cp and 0x3F))
            }
            cp < 0x10000 -> {
                out.write(0xE0 or (cp shr 12))
                out.write(0x80 or ((cp shr 6) and 0x3F))
                out.write(0x80 or (cp and 0x3F))
            }
            else -> {
                out.write(0xF0 or (cp shr 18))
                out.write(0x80 or ((cp shr 12) and 0x3F))
                out.write(0x80 or ((cp shr 6) and 0x3F))
                out.write(0x80 or (cp and 0x3F))
            }
        }
    }

    private const val REPLACEMENT = 0xFFFD
}
