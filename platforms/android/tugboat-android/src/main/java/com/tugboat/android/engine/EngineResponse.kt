package com.tugboat.android.engine

/**
 * One engine response: the raw `tb_session_status` code and a copy of the
 * engine's UTF-8 JSON document (the response on `ok`, an error document
 * otherwise). Constructed from JNI with the signature `(I[B)V`.
 */
internal class EngineResponse(val statusCode: Int, val json: ByteArray) {
    val status: EngineStatus
        get() = EngineStatus.fromCode(statusCode)

    fun text(): String = json.toString(Charsets.UTF_8)
}
