package com.tugboat.android.engine

/**
 * JNI bridge to `libtugboat_engine.so` (engine_jni.cpp). Handles are raw
 * `tb_session_engine*` values; 0 means "no engine". Never throws from native
 * code. Members stay public inside this internal object so Kotlin does not
 * mangle the JNI names.
 */
internal object NativeEngine {
    init {
        System.loadLibrary("tugboat_engine")
    }

    /** 0 for either limit uses the engine default. Returns 0 on failure. */
    external fun create(maxDepth: Int, maxMessageBytes: Long): Long

    /**
     * Submits one UTF-8 JSON message. The engine-owned response is copied
     * into the returned array before this returns. Returns null only when
     * the JVM could not allocate that copy.
     */
    external fun submit(handle: Long, utf8: ByteArray): EngineResponse?

    /** Frees the handle; 0 is a no-op. */
    external fun destroy(handle: Long)
}
