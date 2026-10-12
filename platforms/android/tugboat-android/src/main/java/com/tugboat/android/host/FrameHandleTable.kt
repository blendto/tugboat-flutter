package com.tugboat.android.host

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * Host-side store of encoded frames. The engine only ever sees the opaque
 * handle; JPEG bytes stay here until a `frame.release` effect frees them, or
 * the host releases a handle whose message the engine did not accept.
 * Thread-safe: adapters put from the capture path, the IO executor reads at
 * send time, and the engine thread releases.
 */
internal class FrameHandleTable {
    private val frames = ConcurrentHashMap<String, ByteArray>()
    private val nextId = AtomicLong()

    @Volatile
    private var closed = false

    val size: Int
        get() = frames.size

    /**
     * Stores [jpeg] and returns its new, never reused handle. After [close]
     * the handle is still returned but the bytes are not kept.
     */
    fun put(jpeg: ByteArray): String {
        val handle = "frame-${nextId.incrementAndGet()}"
        frames[handle] = jpeg
        // Checked after the store: a concurrent close() either sees the entry
        // in its clear() or this check sees `closed`.
        if (closed) frames.remove(handle)
        return handle
    }

    /** The bytes for [handle], or null once released (or never stored). */
    operator fun get(handle: String): ByteArray? = frames[handle]

    /** Frees [handle]; false if it was not present. */
    fun release(handle: String): Boolean = frames.remove(handle) != null

    /** Frees everything and stops keeping new frames. */
    fun close() {
        closed = true
        frames.clear()
    }
}
