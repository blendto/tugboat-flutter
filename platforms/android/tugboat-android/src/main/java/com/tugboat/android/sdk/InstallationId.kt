package com.tugboat.android.sdk

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID

/**
 * The SDK's own installation id (BLE-618), with the rules of Flutter's
 * `TugboatInstallationIdStore` (0.11.5): a random UUID minted on first
 * launch and kept in its own file (`tugboat/installation_id`), so it lasts
 * across launches and app updates and is new after a reinstall or when app
 * data is cleared. It is not in the host's shared preferences, so a host that
 * clears them on logout keeps the id.
 *
 * Persistence failures never reach the host: when the file cannot be read or
 * written the id is still returned and stays the same for this process. A
 * failed write is retried on later reads. When several stores race on first
 * launch, the file that ends up on disk wins and every store returns it.
 *
 * The file lives under `filesDir`, where Flutter's support directory is on
 * Android (`path_provider`'s `getApplicationSupportDirectory`), at the same
 * relative path. Like Flutter's, it is not excluded from Auto Backup.
 *
 * Reading and writing it is blocking disk work: the runtime does it on the
 * engine thread ([com.tugboat.android.host.EngineHost.postUntimedLazily]),
 * never on the main thread.
 */
internal class InstallationIdStore(
    /** `<dir>/tugboat/installation_id` is the file; null when the directory is unavailable. */
    private val directory: () -> File?,
    private val mint: () -> String = { UUID.randomUUID().toString() },
) {
    private var resolved: Resolved? = null

    /** The persisted id, minting and persisting one on first call. */
    @Synchronized
    fun read(): String {
        val previous = resolved
        val next = when {
            previous == null -> readOrMint()
            previous.persisted -> previous
            // A result that never reached disk is retried; it keeps its id.
            else -> retry(previous.id)
        }
        resolved = next
        return next.id
    }

    private fun retry(id: String): Resolved {
        val file = file()
        readExisting(file)?.let { return Resolved(it, persisted = true) }
        return store(file, id)
    }

    private fun readOrMint(): Resolved {
        val file = file()
        readExisting(file)?.let { return Resolved(it, persisted = true) }
        return store(file, mint())
    }

    /** Persists [id] and returns the id on disk, so a store that lost a first-launch race adopts the winner's. */
    private fun store(file: File?, id: String): Resolved {
        if (file == null) return Resolved(id, persisted = false)
        return try {
            file.parentFile?.mkdirs()
            if (createExclusive(file, id)) return Resolved(id, persisted = true)
            awaitWinner(file)?.let { return Resolved(it, persisted = true) }
            // The file exists but never became a usable id (a torn write from an earlier launch): replace it.
            if (file.isFile) file.delete()
            val won = createExclusive(file, id)
            Resolved(if (won) id else readExisting(file) ?: id, persisted = won)
        } catch (_: Exception) {
            Resolved(id, persisted = false)
        }
    }

    private fun file(): File? = try {
        directory()?.let { File(File(it, DIRECTORY_NAME), FILE_NAME) }
    } catch (_: Exception) {
        null
    }

    private class Resolved(val id: String, val persisted: Boolean)

    companion object {
        const val DIRECTORY_NAME = "tugboat"
        const val FILE_NAME = "installation_id"

        /** Longest id read back from disk; anything longer is treated as corrupt. */
        const val MAX_LENGTH = 128

        /** The store of [context], under `filesDir`. */
        fun forContext(context: Context): InstallationIdStore =
            InstallationIdStore(directory = { context.filesDir })

        /** A non-empty (after trim) host id wins; otherwise the SDK's own. */
        fun resolve(hostInstallationId: String?, sdkInstallationId: () -> String): String {
            val host = hostInstallationId?.trim()
            if (!host.isNullOrEmpty()) return host
            return sdkInstallationId()
        }

        /** Creates [file] only if absent (atomically) and writes [id] to it; false when another store created it first. */
        private fun createExclusive(file: File, id: String): Boolean {
            if (!file.createNewFile()) return false
            try {
                // Flushed to disk before the file counts as written, as Dart's `flush: true`.
                FileOutputStream(file).use { out ->
                    out.write(id.toByteArray(Charsets.UTF_8))
                    out.fd.sync()
                }
            } catch (e: IOException) {
                file.delete()
                throw e
            }
            return true
        }

        /** Another store created the file; wait briefly for it to finish writing. */
        private fun awaitWinner(file: File): String? {
            repeat(5) {
                readExisting(file)?.let { return it }
                Thread.sleep(20)
            }
            return null
        }

        private fun readExisting(file: File?): String? {
            if (file == null) return null
            return try {
                if (!file.exists()) null else usable(file.readText())
            } catch (_: Exception) {
                null
            }
        }

        private fun usable(value: String?): String? {
            val trimmed = value?.trim()
            if (trimmed.isNullOrEmpty() || trimmed.length > MAX_LENGTH) return null
            return trimmed
        }
    }
}

/** Host entropy for the engine's session and event ids (`session.start.idSeed`). */
internal object IdSeed {
    private val random = SecureRandom()

    /** 32 random bytes as 64 lowercase hex characters; never reused for another session. */
    fun generate(): String {
        val bytes = ByteArray(32).also(random::nextBytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }

    /**
     * The `captureSessionId` the engine mints for [seedHex]: `session-` and the UUIDv4 of the first 16 bytes of
     * SHA-256(seed || big-endian stream index 0) (core/session-engine session.cpp). Derived here so
     * `TUGBOAT_LAUNCH` can print it before the engine thread has answered; `InstallationIdTest` pins it to the
     * engine's vector.
     */
    fun sessionId(seedHex: String): String {
        val seed = ByteArray(32) { seedHex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        val digest = MessageDigest.getInstance("SHA-256").digest(seed + ByteArray(8))
        val b = digest.copyOf(16)
        b[6] = ((b[6].toInt() and 0x0f) or 0x40).toByte()
        b[8] = ((b[8].toInt() and 0x3f) or 0x80).toByte()
        val hex = b.joinToString("") { "%02x".format(it) }
        return "session-${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-" +
            "${hex.substring(16, 20)}-${hex.substring(20)}"
    }
}

/** The process's one [InstallationIdStore], so every session reports the same id. */
internal object InstallationIds {
    private var store: InstallationIdStore? = null

    @Synchronized
    fun forContext(context: Context): InstallationIdStore =
        store ?: InstallationIdStore.forContext(context).also { store = it }

    /** Tests replace the process's store (null restores the default). */
    @Synchronized
    internal fun setStoreForTesting(replacement: InstallationIdStore?) {
        store = replacement
    }

    /** [app] with the installation id a session reports: the host's when non-blank, else the SDK's. */
    fun resolve(context: Context, app: com.tugboat.android.AppInfo): com.tugboat.android.AppInfo =
        app.copy(
            installationId = InstallationIdStore.resolve(app.installationId) { forContext(context).read() },
        )
}
