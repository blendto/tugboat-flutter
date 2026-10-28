package com.tugboat.android.outbox

import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** What an entry's `appIdentity` covers; never written to disk itself. */
internal class OutboxIdentityInputs(val collectorBaseUrl: String, val appId: String, val apiKey: String) {
    /** Never prints the API key. */
    override fun toString(): String = "OutboxIdentityInputs(collectorBaseUrl=$collectorBaseUrl, appId=$appId)"
}

/**
 * `appIdentity`: HMAC-SHA-256, keyed with a random per-install salt kept next
 * to the outbox, over `collectorBaseUrl ‖ appId ‖ apiKey` (W11 design 3.2).
 * An entry whose identity differs from the running config's is deleted
 * unsent. Off the main thread only: the first call reads or creates the salt.
 */
internal class OutboxIdentity(private val saltFile: () -> File) {
    private val lock = Any()
    private var salt: ByteArray? = null

    /** The salt file exists but cannot be read (or is the wrong size): the outbox is off for the process. */
    private var disabled = false
    private var cached: Pair<OutboxIdentityInputs, String>? = null

    /**
     * The identity of [inputs]; null when the salt can neither be read nor
     * created. An existing salt that cannot be read is never replaced (that
     * would orphan every entry): the outbox stays off (no writes, no replay).
     */
    fun of(inputs: OutboxIdentityInputs): String? = synchronized(lock) {
        cached?.takeIf { it.first === inputs }?.let { return it.second }
        val key = salt() ?: return null
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        // Newline-separated, as the Apple host joins them.
        val message = listOf(inputs.collectorBaseUrl, inputs.appId, inputs.apiKey).joinToString("\n")
        val identity = OutboxKeys.hex(mac.doFinal(message.toByteArray(Charsets.UTF_8)))
        cached = inputs to identity
        identity
    }

    private fun salt(): ByteArray? {
        salt?.let { return it }
        if (disabled) return null
        return try {
            val file = saltFile()
            if (!file.exists()) return create(file).also { salt = it }
            val existing = try {
                file.readBytes()
            } catch (_: Throwable) {
                null
            }
            // Readable but the wrong size is corrupt: replaced, as the Apple host does (old entries then mismatch).
            if (existing != null && existing.size != SALT_BYTES) return create(file).also { salt = it }
            existing?.also { salt = it } ?: run {
                disabled = true
                Log.w(TAG, "outbox off for this process: its salt cannot be read")
                null
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun create(file: File): ByteArray {
        val bytes = ByteArray(SALT_BYTES).also(SecureRandom()::nextBytes)
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, ".${file.name}.tmp")
        FileOutputStream(temp).use { out ->
            out.write(bytes)
            out.fd.sync()
        }
        if (!temp.renameTo(file)) temp.delete()
        // Another process may have won the race: use whatever is on disk.
        return file.readBytes().takeIf { it.size == SALT_BYTES } ?: bytes
    }

    private companion object {
        const val TAG = "TugboatOutbox"
        const val SALT_BYTES = 32
    }
}
