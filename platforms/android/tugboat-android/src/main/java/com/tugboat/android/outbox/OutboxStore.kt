package com.tugboat.android.outbox

import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID

/** One entry as `entry.json` describes it. */
internal data class StoredEntry(
    val dirName: String,
    val key: String,
    val lane: OutboxLane,
    val path: String,
    val sessionId: String,
    val createdAtWallMs: Long,
    val lastAttemptWallMs: Long,
    val attempts: Int,
    val processEpoch: String,
    val appIdentity: String,
    val sdkVersion: String,
    /** Bytes of every file in the entry. */
    val bytes: Long,
)

/** What a scan found. */
internal class OutboxScan(
    /** Readable entries, unexpired. */
    val entries: List<StoredEntry>,
    val expired: Int,
    val corrupt: Int,
)

/**
 * The outbox directory: one directory per entry holding `entry.json` and
 * `body` (JSON lanes) or `fields.json` and `frame.jpg` (frames). A new entry
 * is built in a dot-named directory and renamed into place; a changed file is
 * written to a temp file, synced, and renamed. Every method is total: a disk
 * failure is logged and reported as false or skipped, never thrown. Methods
 * hold one lock, so the outbox executor and the drainer never interleave.
 */
internal class OutboxStore(private val rootProvider: () -> File) {
    private val lock = Any()
    private val root: File by lazy(rootProvider)

    /** Writes [capture] as a new entry, or records another attempt on the existing one. */
    fun write(capture: OutboxCapture, dirName: String, meta: EntryMeta, nowMs: Long): Written = guarded("write") {
        synchronized(lock) {
            val dir = File(root, dirName)
            val current = if (dir.isDirectory) read(dir) else null
            if (current == null) create(capture, dir, meta, nowMs) else update(capture, dir, current, meta, nowMs)
        }
    } ?: Written.FAILED

    /** Counts a send of [entry] (the drainer's); false when it is gone. */
    fun recordAttempt(entry: StoredEntry, nowMs: Long): Boolean = guarded("attempt") {
        synchronized(lock) {
            val dir = File(root, entry.dirName)
            val current = read(dir) ?: return@synchronized false
            writeAtomically(File(dir, ENTRY), entryJson(current.copy(attempts = current.attempts + 1, lastAttemptWallMs = nowMs)))
            true
        }
    } ?: false

    fun delete(dirName: String): Boolean = guarded("delete") {
        synchronized(lock) { File(root, dirName).let { !it.exists() || it.deleteRecursively() } }
    } ?: false

    /** Deletes every entry. */
    fun wipe(): Boolean = guarded("wipe") {
        synchronized(lock) { !root.exists() || root.deleteRecursively() }
    } ?: false

    /**
     * Reads every entry, deleting the corrupt ones (unreadable, unknown `v`,
     * a missing file) and those older than [maxAgeMs]. Never throws.
     */
    fun scan(nowMs: Long, maxAgeMs: Long): OutboxScan = guarded("scan") {
        synchronized(lock) { scanLocked(nowMs, maxAgeMs) }
    } ?: OutboxScan(emptyList(), 0, 0)

    fun readBody(dirName: String): ByteArray? = guarded("read") { File(File(root, dirName), BODY).readBytes() }

    fun readFields(dirName: String): String? =
        guarded("read") { File(File(root, dirName), FIELDS).readText(Charsets.UTF_8) }

    /** The JPEG of a frame entry; the drainer's frame handles are entry directory names. */
    fun readFrame(dirName: String): ByteArray? = guarded("read") { File(File(root, dirName), FRAME).readBytes() }

    private fun scanLocked(nowMs: Long, maxAgeMs: Long): OutboxScan {
        val dirs = root.listFiles() ?: return OutboxScan(emptyList(), 0, 0)
        val entries = ArrayList<StoredEntry>()
        var expired = 0
        var corrupt = 0
        for (dir in dirs) {
            if (dir.name.startsWith(".")) {
                // A new entry another writer is still building, or one a crash left half built.
                if (nowMs - dir.lastModified() > STALE_TEMP_MS) dir.deleteRecursively()
                continue
            }
            val entry = read(dir)
            when {
                entry == null -> corrupt += deleteCounted(dir)
                nowMs - entry.createdAtWallMs > maxAgeMs -> expired += deleteCounted(dir)
                else -> entries += entry
            }
        }
        return OutboxScan(entries, expired, corrupt)
    }

    private fun deleteCounted(dir: File): Int = if (dir.deleteRecursively()) 1 else 0

    private fun create(capture: OutboxCapture, dir: File, meta: EntryMeta, nowMs: Long): Written {
        // A directory without a readable entry.json is a corrupt leftover: replace it.
        if (dir.exists()) dir.deleteRecursively()
        dir.parentFile?.mkdirs()
        val building = File(dir.parentFile, ".${dir.name}-${UUID.randomUUID()}")
        if (!building.mkdirs()) throw IOException("cannot create ${building.name}")
        try {
            writeContent(capture, building)
            val entry = StoredEntry(
                dir.name, capture.key, capture.lane, capture.path, capture.sessionId, nowMs, nowMs, 1,
                meta.processEpoch, meta.appIdentity, meta.sdkVersion, 0,
            )
            writeSynced(File(building, ENTRY), entryJson(entry))
            if (!building.renameTo(dir)) throw IOException("cannot rename ${building.name}")
            return Written.CREATED
        } finally {
            if (building.exists()) building.deleteRecursively()
        }
    }

    /** A JSON lane keeps the last body (it is rebuilt per attempt); a frame only counts the attempt. */
    private fun update(capture: OutboxCapture, dir: File, current: StoredEntry, meta: EntryMeta, nowMs: Long): Written {
        val body = capture.body
        if (capture.lane != OutboxLane.FRAMES && body != null) writeAtomically(File(dir, BODY), body)
        val next = current.copy(
            attempts = current.attempts + 1,
            lastAttemptWallMs = nowMs,
            appIdentity = meta.appIdentity,
        )
        writeAtomically(File(dir, ENTRY), entryJson(next))
        return Written.UPDATED
    }

    private fun writeContent(capture: OutboxCapture, dir: File) {
        when (capture.lane) {
            OutboxLane.FRAMES -> {
                writeSynced(File(dir, FIELDS), (capture.fields ?: throw IOException("no fields")).toByteArray(Charsets.UTF_8))
                writeSynced(File(dir, FRAME), capture.jpeg ?: throw IOException("no frame"))
            }
            else -> writeSynced(File(dir, BODY), capture.body ?: throw IOException("no body"))
        }
    }

    private fun read(dir: File): StoredEntry? {
        return try {
            val json = JSONObject(File(dir, ENTRY).readText(Charsets.UTF_8))
            if (json.optInt("v", -1) != VERSION) return null
            val lane = OutboxLane.of(json.getString("lane")) ?: return null
            val files = if (lane == OutboxLane.FRAMES) listOf(FIELDS, FRAME) else listOf(BODY)
            if (files.any { !File(dir, it).isFile }) return null
            StoredEntry(
                dirName = dir.name,
                key = json.getString("key").takeIf { it.isNotBlank() } ?: return null,
                lane = lane,
                path = json.getString("path"),
                sessionId = json.getString("sessionId"),
                createdAtWallMs = json.getLong("createdAtWallMs"),
                lastAttemptWallMs = json.getLong("lastAttemptWallMs"),
                attempts = json.getInt("attempts"),
                processEpoch = json.getString("processEpoch"),
                appIdentity = json.getString("appIdentity"),
                sdkVersion = json.optString("sdkVersion"),
                bytes = (files + ENTRY).sumOf { File(dir, it).length() },
            )
        } catch (_: Throwable) {
            null
        }
    }

    private fun entryJson(entry: StoredEntry): ByteArray =
        JSONObject()
            .put("v", VERSION)
            .put("key", entry.key)
            .put("lane", entry.lane.wire)
            .put("path", entry.path)
            .put("sessionId", entry.sessionId)
            .put("createdAtWallMs", entry.createdAtWallMs)
            .put("lastAttemptWallMs", entry.lastAttemptWallMs)
            .put("attempts", entry.attempts)
            .put("processEpoch", entry.processEpoch)
            .put("appIdentity", entry.appIdentity)
            .put("sdkVersion", entry.sdkVersion)
            .toString()
            .toByteArray(Charsets.UTF_8)

    private fun writeAtomically(file: File, bytes: ByteArray) {
        val temp = File(file.parentFile, ".${file.name}.tmp")
        writeSynced(temp, bytes)
        if (!temp.renameTo(file)) {
            temp.delete()
            throw IOException("cannot rename ${temp.name}")
        }
    }

    private fun writeSynced(file: File, bytes: ByteArray) {
        FileOutputStream(file).use { out ->
            out.write(bytes)
            out.fd.sync()
        }
    }

    private inline fun <T> guarded(what: String, block: () -> T): T? =
        try {
            block()
        } catch (failure: Throwable) {
            try {
                Log.w(TAG, "outbox $what failed: ${failure.javaClass.simpleName}")
            } catch (_: Throwable) {
                // Logging must not throw into the app either.
            }
            null
        }

    enum class Written { CREATED, UPDATED, FAILED }

    /** Who wrote an entry, stamped into `entry.json`. */
    class EntryMeta(val processEpoch: String, val appIdentity: String, val sdkVersion: String)

    companion object {
        const val VERSION = 1
        const val ENTRY = "entry.json"
        const val BODY = "body"
        const val FIELDS = "fields.json"
        const val FRAME = "frame.jpg"
        private const val TAG = "TugboatOutbox"

        /** A dot-named directory older than this is a crashed writer's, not one being built. */
        const val STALE_TEMP_MS = 60_000L
    }
}
