package com.tugboat.android.host

import java.io.ByteArrayOutputStream
import java.security.SecureRandom

/**
 * `multipart/form-data` encoder that writes what Dart's
 * `http.MultipartRequest` writes for the Flutter frame upload: every field
 * first, in order, then every file.
 */
internal class MultipartBody(
    private val fields: List<Pair<String, String>>,
    private val files: List<File>,
    val boundary: String = randomBoundary(),
) {
    class File(val field: String, val filename: String, val contentType: String, val bytes: ByteArray)

    val contentType: String
        get() = "multipart/form-data; boundary=$boundary"

    fun toByteArray(): ByteArray {
        val out = ByteArrayOutputStream()
        for ((name, value) in fields) {
            out.utf8("--$boundary\r\n")
            out.utf8(fieldHeader(name, value))
            out.utf8(value)
            out.utf8("\r\n")
        }
        for (file in files) {
            out.utf8("--$boundary\r\n")
            out.utf8(
                "content-type: ${file.contentType}\r\n" +
                    "content-disposition: form-data; name=\"${encode(file.field)}\"; " +
                    "filename=\"${encode(file.filename)}\"\r\n\r\n",
            )
            out.write(file.bytes)
            out.utf8("\r\n")
        }
        out.utf8("--$boundary--\r\n")
        return out.toByteArray()
    }

    private fun fieldHeader(name: String, value: String): String {
        val disposition = "content-disposition: form-data; name=\"${encode(name)}\""
        val ascii = value.all { it.code < 128 }
        return if (ascii) {
            "$disposition\r\n\r\n"
        } else {
            "$disposition\r\ncontent-type: text/plain; charset=utf-8\r\n" +
                "content-transfer-encoding: binary\r\n\r\n"
        }
    }

    private fun ByteArrayOutputStream.utf8(text: String) = write(text.toByteArray(Charsets.UTF_8))

    private companion object {
        val NEWLINE = Regex("\r\n|\r|\n")
        const val BOUNDARY_CHARS = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        val random = SecureRandom()

        /** Browser-style encoding of names, as Dart's `_browserEncode`. */
        fun encode(value: String): String = value.replace(NEWLINE, "%0D%0A").replace("\"", "%22")

        fun randomBoundary(): String =
            "tugboat-boundary-" + (1..32).map { BOUNDARY_CHARS[random.nextInt(BOUNDARY_CHARS.length)] }.joinToString("")
    }
}
