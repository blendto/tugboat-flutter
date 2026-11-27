package com.tugboat.android.host

/** Minimal `multipart/form-data` parser for asserting on request bodies. */
internal class MultipartParts private constructor(
    val headers: Map<String, String>,
    val bytes: ByteArray,
) {
    private val disposition = headers["content-disposition"].orEmpty()

    val name: String? = param("name")
    val filename: String? = param("filename")
    val contentType: String? = headers["content-type"]
    val text: String
        get() = bytes.toString(Charsets.UTF_8)

    private fun param(key: String): String? =
        Regex("""(?:^|; )$key="([^"]*)"""").find(disposition)?.groupValues?.get(1)

    companion object {
        fun parse(body: ByteArray, boundary: String): List<MultipartParts> {
            // ISO-8859-1 maps bytes 1:1 to chars, so offsets are byte offsets.
            val text = String(body, Charsets.ISO_8859_1)
            val delimiter = "--$boundary"
            require(text.endsWith("$delimiter--\r\n")) { "missing closing delimiter" }
            return text.removeSuffix("$delimiter--\r\n").split("$delimiter\r\n").drop(1).map { part ->
                val headerEnd = part.indexOf("\r\n\r\n")
                val headers = part.substring(0, headerEnd).split("\r\n").associate { line ->
                    line.substringBefore(": ").lowercase() to line.substringAfter(": ")
                }
                val content = part.substring(headerEnd + 4).removeSuffix("\r\n")
                MultipartParts(headers, content.toByteArray(Charsets.ISO_8859_1))
            }
        }
    }
}
