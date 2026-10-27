package com.tugboat.android.outbox

import android.content.Context
import android.util.Log
import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * The durable outbox of one process (W11 design 3): the entry directory, the
 * serial outbox executor that writes and deletes entries, the keys with a
 * request in flight, and the current session. It outlives sessions: an entry
 * written in one session is replayed by a later one ([OutboxDrainer]).
 * Nothing here touches the disk on the calling thread except [OutboxDrainer]'s
 * own; nothing throws.
 */
internal class Outbox(
    /** `noBackupFilesDir/tugboat/outbox`; resolved off the main thread, on first use. */
    root: () -> File,
    /** Random per process: an entry from another epoch is an orphan. */
    val processEpoch: String = UUID.randomUUID().toString(),
    val wallMs: () -> Long = System::currentTimeMillis,
    private val io: Executor = serialExecutor(),
) {
    private val rootDir: File by lazy(root)
    val store = OutboxStore { File(rootDir, "v1") }
    val identity = OutboxIdentity { File(rootDir, "install-salt") }
    val active = ActiveKeys()

    @Volatile
    var settings: OutboxSettings = OutboxSettings.DEFAULT

    /** The `sessionId` of the most recent `http.send`; null before any. */
    @Volatile
    var currentSession: String? = null
        private set

    private val sessionListeners = CopyOnWriteArraySet<() -> Unit>()

    /** Requests sent without an entry: no key could be derived. */
    val unkeyed = AtomicInteger()

    /** Entry writes that failed; their requests were still sent. */
    val writeFailures = AtomicInteger()

    /** Entries evicted for the bounds since the last drain pass reported them. */
    val evicted = AtomicInteger()

    /** Disk usage as of the last scan plus later writes; drives eviction between scans. */
    private val approxBytes = AtomicLong()
    private val approxEntries = AtomicInteger()

    fun dirName(key: String): String = "$processEpoch-${OutboxKeys.sha256Hex(key).take(20)}"

    /** An entry of another process, or of a session other than the current one. */
    fun isOrphan(entry: StoredEntry): Boolean {
        if (entry.processEpoch != processEpoch) return true
        val current = currentSession ?: return false
        return entry.sessionId != current
    }

    /** Engine thread, per keyed `http.send`: a new session makes the last one's entries orphans. */
    fun noteSession(sessionId: String) {
        if (currentSession == sessionId) return
        currentSession = sessionId
        sessionListeners.forEach { listener -> guarded("session listener") { listener() } }
    }

    fun addSessionListener(listener: () -> Unit) = sessionListeners.add(listener)

    fun removeSessionListener(listener: () -> Unit) = sessionListeners.remove(listener)

    /** Queues the entry writes of one send; a failure is counted, never thrown. */
    fun write(captures: List<OutboxCapture>, inputs: OutboxIdentityInputs, sdkVersion: String) = submit("write") {
        val meta = OutboxStore.EntryMeta(processEpoch, identity.of(inputs).orEmpty(), sdkVersion)
        val now = wallMs()
        for (capture in captures) {
            when (store.write(capture, dirName(capture.key), meta, now)) {
                OutboxStore.Written.CREATED -> {
                    approxEntries.incrementAndGet()
                    approxBytes.addAndGet((capture.body?.size ?: 0).toLong() + (capture.jpeg?.size ?: 0) + ENTRY_OVERHEAD)
                }
                OutboxStore.Written.UPDATED -> Unit
                OutboxStore.Written.FAILED -> writeFailures.incrementAndGet()
            }
        }
        if (approxBytes.get() > settings.maxBytes || approxEntries.get() > settings.maxEntries) scanAndEvict()
    }

    /**
     * Queues the delete of [key]'s entry after an answer that ends it,
     * unless a later attempt at [key] is in flight by the time it runs.
     */
    fun deleteAnswered(key: String, attempt: Long) = submit("delete") {
        if (!active.hasNewer(key, attempt)) store.delete(dirName(key))
    }

    /** Queues the delete of every entry (start with the outbox off, `Tugboat.clearPendingData`). */
    fun wipe() = submit("wipe") {
        store.wipe()
        approxBytes.set(0)
        approxEntries.set(0)
    }

    /** Waits up to [timeoutMs] for every queued write and delete; true when they landed. */
    fun awaitQueued(timeoutMs: Long): Boolean {
        val landed = CountDownLatch(1)
        if (!submit("barrier") { landed.countDown() }) return false
        return try {
            landed.await(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
    }

    /**
     * Scans the directory, deleting corrupt and expired entries, then evicts
     * for the bounds. Holds the store's lock per call, from any thread.
     */
    fun scanAndEvict(): ScanReport {
        val current = settings
        val scan = store.scan(wallMs(), current.maxAgeMs)
        val evictions = OutboxPolicy.evictions(scan.entries, current, ::isOrphan, active::isActive)
        val gone = evictions.filter { store.delete(it.dirName) }.map { it.dirName }.toSet()
        evicted.addAndGet(gone.size)
        val kept = scan.entries.filter { it.dirName !in gone }
        approxBytes.set(kept.sumOf { it.bytes })
        approxEntries.set(kept.size)
        return ScanReport(kept, scan.expired, scan.corrupt)
    }

    private fun submit(what: String, block: () -> Unit): Boolean =
        try {
            io.execute { guarded(what, block) }
            true
        } catch (_: Throwable) {
            false
        }

    class ScanReport(val entries: List<StoredEntry>, val expired: Int, val corrupt: Int)

    companion object {
        private const val TAG = "TugboatOutbox"

        /** `entry.json` and fields, roughly, for the bound check between scans. */
        private const val ENTRY_OVERHEAD = 512L

        /** One thread that exits when idle, so a process with nothing to write keeps none. */
        fun serialExecutor(): Executor =
            ThreadPoolExecutor(1, 1, 5, TimeUnit.SECONDS, LinkedBlockingQueue()) { task ->
                Thread(task, "tugboat-outbox").apply { isDaemon = true }
            }.apply { allowCoreThreadTimeOut(true) }

        inline fun guarded(what: String, block: () -> Unit) {
            try {
                block()
            } catch (failure: Throwable) {
                try {
                    Log.w(TAG, "outbox $what failed: ${failure.javaClass.simpleName}")
                } catch (_: Throwable) {
                    // Logging must not throw into the app either.
                }
            }
        }
    }
}

/**
 * Keys with a host request in flight, each attempt numbered from one
 * process-wide sequence. Thread-safe.
 */
internal class ActiveKeys {
    private val sequence = AtomicLong()
    private val inFlight = HashMap<String, MutableList<Long>>()

    /** Marks an attempt at [key] as in flight; returns its number. */
    fun begin(key: String): Long = synchronized(inFlight) {
        val attempt = sequence.incrementAndGet()
        inFlight.getOrPut(key) { ArrayList(1) } += attempt
        attempt
    }

    fun end(key: String, attempt: Long) = synchronized(inFlight) {
        val attempts = inFlight[key] ?: return@synchronized
        attempts.remove(attempt)
        if (attempts.isEmpty()) inFlight.remove(key)
    }

    fun isActive(key: String): Boolean = synchronized(inFlight) { inFlight.containsKey(key) }

    /** Whether an attempt at [key] later than [attempt] is in flight. */
    fun hasNewer(key: String, attempt: Long): Boolean = synchronized(inFlight) {
        inFlight[key]?.any { it > attempt } == true
    }
}

/** The process's outbox, created by the first `Tugboat.start`; kept across `stop`. */
internal object Outboxes {
    @Volatile
    private var outbox: Outbox? = null

    /** A `clearPendingData` made before any `start`: applied by the first. */
    @Volatile
    private var pendingClear = false

    fun at(context: Context): Outbox = synchronized(this) {
        outbox ?: Outbox(root = { File(context.noBackupFilesDir, "tugboat/outbox") }).also { outbox = it }
    }

    /** Wipes the outbox now, or at the first `start` when none exists yet. */
    fun clear() = synchronized(this) {
        val current = outbox
        if (current == null) pendingClear = true else current.wipe()
    }

    /** Whether a `clear` waits for this start; resets it. */
    fun takePendingClear(): Boolean = synchronized(this) { pendingClear.also { pendingClear = false } }

    /** JVM tests only. */
    internal fun resetForTests(replacement: Outbox? = null) = synchronized(this) {
        outbox = replacement
        pendingClear = false
    }
}
