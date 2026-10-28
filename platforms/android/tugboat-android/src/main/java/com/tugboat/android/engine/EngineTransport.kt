package com.tugboat.android.engine

import android.util.Log

/**
 * The seam between the host and one engine handle. Implementations are not
 * thread-safe: the host calls them from its engine thread only.
 */
internal interface EngineTransport {
    fun submit(message: ByteArray): EngineResponse

    /** Releases the handle. Later submits answer [EngineStatus.INVALID_ARGUMENT]. */
    fun close()
}

/** [EngineTransport] over the real engine through [NativeEngine]. */
internal class JniEngineTransport private constructor(private var handle: Long) : EngineTransport {
    override fun submit(message: ByteArray): EngineResponse =
        NativeEngine.submit(handle, message)
            ?: EngineResponse(EngineStatus.OUT_OF_MEMORY.code, ByteArray(0))

    override fun close() {
        NativeEngine.destroy(handle)
        handle = 0
    }

    companion object {
        private const val TAG = "TugboatEngine"

        /**
         * Loads the library and creates a handle; null when either fails.
         * 0 for a limit uses the engine default.
         */
        fun open(maxDepth: Int = 0, maxMessageBytes: Long = 0): JniEngineTransport? {
            val handle = try {
                NativeEngine.create(maxDepth, maxMessageBytes)
            } catch (error: LinkageError) {
                // UnsatisfiedLinkError or ExceptionInInitializerError.
                Log.w(TAG, "session engine library unavailable", error)
                return null
            }
            if (handle == 0L) {
                Log.w(TAG, "session engine create failed")
                return null
            }
            return JniEngineTransport(handle)
        }
    }
}
