package com.tugboat.android.okhttp

import com.tugboat.android.adapter.HttpErrorBody
import okhttp3.Response
import java.util.Locale

/**
 * Reads an HTTP error response body without consuming it
 * (`core/session-engine/docs/evidence-messages.md` section 4.5, "a
 * byte-reading adapter"):
 *
 * - [Response.peekBody] of 65,537 bytes. The body is complete if and only if
 *   at most 65,536 bytes came back (`Content-Length` is not trusted). The
 *   app's body is untouched: peeking buffers bytes that the app reads later.
 * - JSON when `Content-Type` (case-insensitive, parameters ignored) is
 *   `application/json`, `text/json`, or a `+json` subtype (Dio's rule).
 * - Decoded as UTF-8 with maximal-subpart U+FFFD replacement ([Utf8]).
 * - Complete and JSON: [HttpErrorBody.jsonText], the whole body. Otherwise
 *   [HttpErrorBody.text], cut to the whole characters within the first 4100
 *   UTF-8 bytes (any prefix past 4096 bytes keeps the engine's text body
 *   exact).
 */
internal object ErrorBodies {
    const val PEEK_BYTES = 65_537L
    const val COMPLETE_BYTES = 65_536
    const val TEXT_BYTES = 4_100

    /** The body of [response], or null when it has none to read. May throw (the caller drops the body). */
    fun read(response: Response): HttpErrorBody? {
        if (response.body() == null) return null
        val bytes = response.peekBody(PEEK_BYTES).bytes()
        return classify(bytes, response.header("Content-Type"))
    }

    fun classify(bytes: ByteArray, contentType: String?): HttpErrorBody {
        val complete = bytes.size <= COMPLETE_BYTES
        return if (complete && isJson(contentType)) {
            HttpErrorBody.jsonText(Utf8.decode(bytes))
        } else {
            HttpErrorBody.text(Utf8.decode(bytes, maxUtf8Bytes = TEXT_BYTES))
        }
    }

    /**
     * `application/json`, `text/json`, or `type/…+json`, case-insensitive,
     * parameters ignored: Dio's `Transformer.isJsonMimeType`.
     */
    fun isJson(contentType: String?): Boolean {
        if (contentType == null) return false
        val essence = contentType.substringBefore(';').trim { it == ' ' || it == '\t' }.lowercase(Locale.ROOT)
        val slash = essence.indexOf('/')
        if (slash <= 0 || slash == essence.length - 1 || essence.indexOf('/', slash + 1) >= 0) return false
        return essence == "application/json" || essence == "text/json" || essence.endsWith("+json")
    }
}
