package com.tugboat.android.adapter

/**
 * An error response body an HTTP-client adapter read as bytes, passed as
 * [com.tugboat.android.NetworkCall.complete]'s `errorResponseBody`
 * (`core/session-engine/docs/evidence-messages.md` section 4.5, "a
 * byte-reading adapter"). The adapter peeks, classifies, and decodes the
 * bytes; the encoder sends a [jsonText] body as `{"jsonText": …}` and a
 * [text] body as `{"value": …}`, and the engine bounds both. Like every
 * body, it is read only for status 400 or more.
 */
@TugboatAdapterApi
class HttpErrorBody private constructor(internal val body: String, internal val isJsonText: Boolean) {
    companion object {
        /** The complete body of a JSON media type, decoded but not parsed. Sent whole: the engine parses it. */
        @JvmStatic
        fun jsonText(body: String): HttpErrorBody = HttpErrorBody(body, isJsonText = true)

        /** Any other body, or a JSON one that was not read whole, as text. */
        @JvmStatic
        fun text(text: String): HttpErrorBody = HttpErrorBody(text, isJsonText = false)
    }
}
