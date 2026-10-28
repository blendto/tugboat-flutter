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
    /** Every send, the engine's re-sends included; diagnostic. */
    val attempts: Long,
    /** The drainer's sends only, across launches: what `outboxMaxAttempts` and the backoff count. */
    val replays: Long,
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
    /** Entries whose files exist but cannot be read now: skipped, never deleted. */
    val unreadable: Int = 0,
)

/** What a replay sends, read from disk. */
internal sealed interface OutboxPayload {
    class Json(val text: String) : OutboxPayload

    /** [fields] is `fields.json`; the JPEG is read at send time ([OutboxStore.readFrame]). */
    class Frame(val fields: String) : OutboxPayload

    /** A file is gone: the entry is corrupt. */
    object Missing : OutboxPayload

    /** A file exists but cannot be read now: skip the entry this pass. */
    object Unreadable : OutboxPayload
}

/**
 * The outbox directory: one directory per entry holding `entry.json` and
 * `body` (JSON lanes) or `fields.json` and `frame.jpg` (frames). A new entry
 * is built in a dot-named directory and renamed into place; a changed file is
 * written to a temp file, synced, and renamed. Every method is total: a disk
 * failure is logged and reported as false or skipped, never thrown. Methods
 * hold one lock, so the outbox executor and the drainer never interleave.
 *
 * Only a missing file, unparseable JSON, an unknown `v`, or a number outside
 * 0..2^52 makes an entry corrupt (deleted). A file that exists but cannot be
 * read is skipped and kept.
 */
internal class OutboxStore(private val rootProvider: () -> File) {
    private val lock = Any()
    private val root: File by lazy(rootProvider)

    /** Writes [capture] as a new entry, or records another attempt on the existing one. */
    fun write(capture: OutboxCapture, dirName: String, meta: EntryMeta, nowMs: Long): Written = guarded("write") {
        synchronized(lock) {
            val dir = File(root, dirName)
            when (val current = if (dir.isDirectory) read(dir) else ReadResult.Corrupt) {
                is ReadResult.Ok -> update(capture, dir, current.entry, meta, nowMs)
                ReadResult.Corrupt -> create(capture, dir, meta, nowMs)
                // Never replaced while it cannot be read.
                ReadResult.Unreadable -> Written.FAILED
            }
        }
    } ?: Written.FAILED

    /** Counts a replay of [entry] (`replays` and `attempts`); the updated entry, or null when it is gone or unreadable. */
    fun recordReplay(entry: StoredEntry, nowMs: Long): StoredEntry? = guarded("replay") {
        synchronized(lock) {
            val dir = File(root, entry.dirName)
            val current = (read(dir) as? ReadResult.Ok)?.entry ?: return@synchronized null
            val next = current.copy(
                attempts = bumped(current.attempts),
                replays = bumped(current.replays),
                lastAttemptWallMs = nowMs,
            )
            writeAtomically(File(dir, ENTRY), entryJson(next))
            next
        }
    }

    /** Undoes [recordReplay] for a replay that never started; [counted] is what it returned. */
    fun unrecordReplay(counted: StoredEntry): Boolean = guarded("unreplay") {
        synchronized(lock) {
            val dir = File(root, counted.dirName)
            val current = (read(dir) as? ReadResult.Ok)?.entry ?: return@synchronized false
            val next = current.copy(
                attempts = (current.attempts - 1).coerceAtLeast(0),
                replays = (current.replays - 1).coerceAtLeast(0),
            )
            writeAtomically(File(dir, ENTRY), entryJson(next))
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
     * Reads every entry, deleting the corrupt ones and those older than
     * [maxAgeMs]; unreadable ones are skipped and kept. Never throws.
     */
    fun scan(nowMs: Long, maxAgeMs: Long): OutboxScan = guarded("scan") {
        synchronized(lock) { scanLocked(nowMs, maxAgeMs) }
    } ?: OutboxScan(emptyList(), 0, 0)

    /** The body or fields of [entry] for a replay. */
    fun payload(entry: StoredEntry): OutboxPayload = guarded("read") {
        synchronized(lock) {
            val dir = File(root, entry.dirName)
            if (entry.lane == OutboxLane.FRAMES) {
                val frame = File(dir, FRAME)
                if (!frame.isFile) return@synchronized OutboxPayload.Missing
                if (!frame.canRead()) return@synchronized OutboxPayload.Unreadable
                when (val fields = readFile(File(dir, FIELDS))) {
                    is FileRead.Bytes -> OutboxPayload.Frame(String(fields.bytes, Charsets.UTF_8))
                    FileRead.Missing -> OutboxPayload.Missing
                    FileRead.Unreadable -> OutboxPayload.Unreadable
                }
            } else {
                when (val body = readFile(File(dir, BODY))) {
                    is FileRead.Bytes -> OutboxPayload.Json(String(body.bytes, Charsets.UTF_8))
                    FileRead.Missing -> OutboxPayload.Missing
                    FileRead.Unreadable -> OutboxPayload.Unreadable
                }
            }
        }
    } ?: OutboxPayload.Unreadable

    /** The JPEG of a frame entry; the drainer's frame handles are entry directory names. */
    fun readFrame(dirName: String): ByteArray? = guarded("read") { File(File(root, dirName), FRAME).readBytes() }

    private fun scanLocked(nowMs: Long, maxAgeMs: Long): OutboxScan {
        val dirs = root.listFiles() ?: return OutboxScan(emptyList(), 0, 0)
        val entries = ArrayList<StoredEntry>()
        var expired = 0
        var corrupt = 0
        var unreadable = 0
        for (dir in dirs) {
            if (dir.name.startsWith(".")) {
                // A new entry another writer is still building, or one a crash left half built.
                if (nowMs - dir.lastModified() > STALE_TEMP_MS) dir.deleteRecursively()
                continue
            }
            when (val read = read(dir)) {
                ReadResult.Corrupt -> corrupt += deleteCounted(dir)
                ReadResult.Unreadable -> unreadable++
                is ReadResult.Ok ->
                    // Both are within 0..2^52 (read checks), so the difference cannot overflow.
                    if (nowMs - read.entry.createdAtWallMs > maxAgeMs) expired += deleteCounted(dir) else entries += read.entry
            }
        }
        return OutboxScan(entries, expired, corrupt, unreadable)
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
                dir.name, capture.key, capture.lane, capture.path, capture.sessionId, nowMs, nowMs, 1, 0,
                meta.processEpoch, meta.appIdentity, meta.sdkVersion, 0,
            )
            writeSynced(File(building, ENTRY), entryJson(entry))
            if (!building.renameTo(dir)) throw IOException("cannot rename ${building.name}")
            return Written.CREATED
        } finally {
            if (building.exists()) building.deleteRecursively()
        }
    }

    /**
     * A JSON lane keeps the last body (it is rebuilt per attempt); a frame
     * only counts the attempt. Engine re-sends never touch `replays`.
     */
    private fun update(capture: OutboxCapture, dir: File, current: StoredEntry, meta: EntryMeta, nowMs: Long): Written {
        val body = capture.body
        if (capture.lane != OutboxLane.FRAMES && body != null) writeAtomically(File(dir, BODY), body)
        val next = current.copy(
            attempts = bumped(current.attempts),
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

    private fun read(dir: File): ReadResult {
        val text = when (val file = readFile(File(dir, ENTRY))) {
            is FileRead.Bytes -> String(file.bytes, Charsets.UTF_8)
            FileRead.Missing -> return ReadResult.Corrupt
            FileRead.Unreadable -> return ReadResult.Unreadable
        }
        return try {
            val json = JSONObject(text)
            if (json.optInt("v", -1) != VERSION) return ReadResult.Corrupt
            val lane = OutboxLane.of(json.getString("lane")) ?: return ReadResult.Corrupt
            val files = if (lane == OutboxLane.FRAMES) listOf(FIELDS, FRAME) else listOf(BODY)
            if (files.any { !File(dir, it).isFile }) return ReadResult.Corrupt
            ReadResult.Ok(
                StoredEntry(
                    dirName = dir.name,
                    key = json.getString("key").takeIf { it.isNotBlank() } ?: return ReadResult.Corrupt,
                    lane = lane,
                    path = json.getString("path"),
                    sessionId = json.getString("sessionId"),
                    createdAtWallMs = json.number("createdAtWallMs") ?: return ReadResult.Corrupt,
                    lastAttemptWallMs = json.number("lastAttemptWallMs") ?: return ReadResult.Corrupt,
                    attempts = json.number("attempts") ?: return ReadResult.Corrupt,
                    // Absent in entries written before it existed: no replays yet.
                    replays = if (json.has("replays")) json.number("replays") ?: return ReadResult.Corrupt else 0,
                    processEpoch = json.getString("processEpoch"),
                    appIdentity = json.getString("appIdentity"),
                    sdkVersion = json.optString("sdkVersion"),
                    bytes = (files + ENTRY).sumOf { File(dir, it).length() },
                ),
            )
        } catch (_: Throwable) {
            ReadResult.Corrupt
        }
    }

    private fun readFile(file: File): FileRead {
        if (!file.isFile) return FileRead.Missing
        return try {
            FileRead.Bytes(file.readBytes())
        } catch (_: Throwable) {
            // It exists: a permission or IO problem, not a bad entry.
            FileRead.Unreadable
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
            .put("replays", entry.replays)
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

    private sealed interface ReadResult {
        class Ok(val entry: StoredEntry) : ReadResult

        object Corrupt : ReadResult

        object Unreadable : ReadResult
    }

    private sealed interface FileRead {
        class Bytes(val bytes: ByteArray) : FileRead

        object Missing : FileRead

        object Unreadable : FileRead
    }

    companion object {
        const val VERSION = 1
        const val ENTRY = "entry.json"
        const val BODY = "body"
        const val FIELDS = "fields.json"
        const val FRAME = "frame.jpg"
        private const val TAG = "TugboatOutbox"

        /** A dot-named directory older than this is a crashed writer's, not one being built. */
        const val STALE_TEMP_MS = 60_000L

        /** The largest number read from disk (2^52): exact in a double, so no reader or sum overflows. */
        const val MAX_NUMBER = 1L shl 52

        private fun bumped(count: Long): Long = minOf(MAX_NUMBER, count + 1)

        /** A whole number in 0..[MAX_NUMBER], or null. */
        private fun JSONObject.number(name: String): Long? {
            val value = opt(name) as? Number ?: return null
            val asDouble = value.toDouble()
            if (asDouble.isNaN() || asDouble < 0 || asDouble > MAX_NUMBER.toDouble()) return null
            val asLong = value.toLong()
            return if (asLong.toDouble() == asDouble) asLong else null
        }
    }
}
