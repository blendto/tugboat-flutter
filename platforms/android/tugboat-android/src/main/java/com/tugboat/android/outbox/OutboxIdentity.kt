package com.tugboat.android.outbox

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
    private var cached: Pair<OutboxIdentityInputs, String>? = null

    /** The identity of [inputs]; null when the salt can neither be read nor created. */
    fun of(inputs: OutboxIdentityInputs): String? = synchronized(lock) {
        cached?.takeIf { it.first === inputs }?.let { return it.second }
        val key = salt() ?: return null
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        // NUL-separated so no two input triples share a message.
        val message = listOf(inputs.collectorBaseUrl, inputs.appId, inputs.apiKey).joinToString("\u0000")
        val identity = OutboxKeys.hex(mac.doFinal(message.toByteArray(Charsets.UTF_8)))
        cached = inputs to identity
        identity
    }

    private fun salt(): ByteArray? {
        salt?.let { return it }
        return try {
            val file = saltFile()
            val existing = if (file.isFile) file.readBytes().takeIf { it.size == SALT_BYTES } else null
            (existing ?: create(file)).also { salt = it }
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
        const val SALT_BYTES = 32
    }
}
