package com.tugboat.android.outbox

import android.util.Log
import com.tugboat.android.host.FramePart
import com.tugboat.android.host.HttpBody
import com.tugboat.android.host.HttpRequest
import com.tugboat.android.host.TransportOutcome
import com.tugboat.android.sdk.SessionEndWatcher
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Replays orphaned outbox entries (W11 design 3.3), one request at a time on
 * its own IO thread, beside the engine's one. It never uses the engine's IO
 * thread, where a replay would hold engine requests past their answer
 * deadline. There is one drainer per running session: it starts after
 * `session.start` is posted and stops with the session, so nothing is sent
 * while dormant.
 *
 * A pass runs at [start], whenever the current session changes, and after a
 * backoff when the collector asks to retry. It scans (deleting corrupt and
 * expired entries, evicting for the bounds), then sends orphans oldest
 * first, skipping any key with a request in flight. The first retried answer
 * ends the pass. One log line per pass (tag `TugboatOutbox`).
 */
internal class OutboxDrainer(
    private val outbox: Outbox,
    private val inputs: OutboxIdentityInputs,
    /**
     * Starts one request on the drainer's own IO thread and answers it once;
     * normally `HttpExecutor.send` of an executor over [OutboxStore.readFrame].
     */
    private val send: (HttpRequest, (TransportOutcome) -> Unit) -> Unit,
    private val scheduler: ScheduledExecutorService = newScheduler(),
    /** Runs at [stop]; closes what [send] uses. */
    private val onStop: () -> Unit = {},
    private val log: (String) -> Unit = { line -> Log.i(TAG, line) },
) {
    /** Guards [stopped] and the start of every replay request: none starts once [stop] returned. */
    private val fence = Any()
    private var stopped = false
    private var pending: ScheduledFuture<*>? = null
    private val onSessionChanged: () -> Unit = { request(0) }

    /** JVM tests only: runs on the drainer thread just before a replay request would start. */
    internal var beforeSendForTesting: (() -> Unit)? = null

    fun start() {
        outbox.addSessionListener(onSessionChanged)
        request(0)
    }

    /**
     * No replay request starts after this returns. A request already started
     * finishes (bounded by its timeout), and its answer is still applied.
     */
    fun stop() {
        synchronized(fence) { stopped = true }
        outbox.removeSessionListener(onSessionChanged)
        synchronized(this) { pending?.cancel(false) }
        try {
            scheduler.shutdownNow()
            onStop()
        } catch (failure: Throwable) {
            Log.w(TAG, "outbox drainer stop failed: ${failure.javaClass.simpleName}")
        }
    }

    private val isStopped: Boolean
        get() = synchronized(fence) { stopped }

    /** Schedules a pass in [delayMs], unless one is already due sooner. */
    private fun request(delayMs: Long) = synchronized(this) {
        if (isStopped) return@synchronized
        val current = pending
        if (current != null && !current.isDone && current.getDelay(TimeUnit.MILLISECONDS) in 0..delayMs) return@synchronized
        current?.cancel(false)
        pending = try {
            scheduler.schedule({ Outbox.guarded("drain pass", ::pass) }, delayMs, TimeUnit.MILLISECONDS)
        } catch (_: Throwable) {
            null
        }
    }

    private fun pass() {
        if (isStopped) return
        // Wipes and writes queued before this pass land first.
        outbox.awaitQueued(AWAIT_QUEUED_MS)
        val scan = outbox.scanAndEvict()
        val report = PassReport(expired = scan.expired, corrupt = scan.corrupt)
        // Null when the salt cannot be read: the outbox is off for the process.
        val identity = outbox.identity.of(inputs)
        var retryInMs: Long? = null
        if (identity != null) {
            for (entry in scan.entries.sortedWith(compareBy<StoredEntry> { it.createdAtWallMs }.thenBy { it.key })) {
                if (isStopped) break
                if (!outbox.isOrphan(entry) || outbox.active.isActive(entry.key)) continue
                retryInMs = replay(entry, identity, report)
                if (retryInMs != null) break
            }
        }
        report.evicted = outbox.evicted.getAndSet(0)
        report.bytesOnDisk = scan.entries.sumOf { it.bytes } - report.freedBytes
        log(report.line())
        retryInMs?.let(::request)
    }

    /** Sends [entry] once; null to go on with the pass, else the delay before the next one. */
    private fun replay(entry: StoredEntry, identity: String, report: PassReport): Long? {
        when {
            entry.appIdentity != identity -> report.identityMismatch += report.deleted(entry)
            // Only replays count: the engine's re-sends during an outage never use the budget up.
            entry.replays >= outbox.settings.maxAttempts -> report.expired += report.deleted(entry)
            else -> return send(entry, report)
        }
        return null
    }

    private fun send(entry: StoredEntry, report: PassReport): Long? {
        val request = when (val payload = outbox.store.payload(entry)) {
            OutboxPayload.Missing -> {
                report.corrupt += report.deleted(entry)
                return null
            }
            // Kept, and tried again next pass.
            OutboxPayload.Unreadable -> return null
            else -> requestFor(entry, payload) ?: run {
                report.corrupt += report.deleted(entry)
                return null
            }
        }
        val attempt = outbox.active.begin(entry.key)
        val outcome = try {
            // Counted before the send: a crash mid-send still uses up a replay.
            val counted = outbox.store.recordReplay(entry, outbox.wallMs()) ?: return null
            val answered = sendFenced(request) ?: run {
                // stop() ran first and nothing was sent: the replay does not count, or start/stop
                // races would expire an entry that was never sent.
                outbox.store.unrecordReplay(counted)
                return null
            }
            if (!SessionEndWatcher.isFinal(answered)) {
                val retryAfter = (answered as? TransportOutcome.Http)?.retryAfter
                val replays = counted.replays.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                return OutboxBackoff.delayMs(replays, retryAfter, outbox.wallMs())
            }
            answered
        } finally {
            outbox.active.end(entry.key, attempt)
        }
        if (!outbox.active.hasNewer(entry.key, attempt) && outbox.store.delete(entry.dirName)) report.freedBytes += entry.bytes
        // Every settled replay, accepted or dropped, as the Apple host counts it.
        if (outcome is TransportOutcome.Http) report.replayed++
        return null
    }

    /** The answer to [request], or null when [stop] ran first (then nothing was sent). */
    private fun sendFenced(request: HttpRequest): TransportOutcome? {
        beforeSendForTesting?.invoke()
        val answer = AtomicReference<TransportOutcome>()
        val answered = CountDownLatch(1)
        synchronized(fence) {
            if (stopped) return null
            send(request) { outcome ->
                answer.set(outcome)
                answered.countDown()
            }
        }
        return try {
            if (answered.await(ANSWER_WAIT_MS, TimeUnit.MILLISECONDS)) answer.get() else TransportOutcome.Timeout
        } catch (_: InterruptedException) {
            // stop() interrupted the wait; the request keeps its own deadline.
            Thread.currentThread().interrupt()
            TransportOutcome.Timeout
        }
    }

    private fun PassReport.deleted(entry: StoredEntry): Int {
        if (!outbox.store.delete(entry.dirName)) return 0
        freedBytes += entry.bytes
        return 1
    }

    private fun requestFor(entry: StoredEntry, payload: OutboxPayload): HttpRequest? {
        val body = when (payload) {
            is OutboxPayload.Frame -> {
                val fields = OutboxKeys.frameFields(payload.fields) ?: return null
                val frameNo = fields.firstOrNull { it.first == OutboxKeys.FRAMES_FIELD_NUMBERS }?.second ?: return null
                // The frame handle is the entry directory: [OutboxStore.readFrame] resolves it at send time.
                HttpBody.Multipart(fields, listOf(FramePart(entry.dirName, "$frameNo.jpg")))
            }
            is OutboxPayload.Json -> HttpBody.Json(payload.text)
            else -> return null
        }
        return HttpRequest(
            requestId = "outbox-${entry.dirName}",
            lane = entry.lane.wire,
            path = entry.path,
            timeoutMs = REPLAY_TIMEOUT_MS,
            body = body,
            headers = mapOf(OutboxKeys.HEADER to entry.key),
        )
    }

    /** One pass's counts: the `TugboatOutbox` log line, with the design's fields in the Apple host's format. */
    class PassReport(var expired: Int = 0, var corrupt: Int = 0) {
        /** Settled replays: accepted, or dropped for good. */
        var replayed = 0
        var evicted = 0
        var identityMismatch = 0
        var bytesOnDisk = 0L
        var freedBytes = 0L

        fun line(prefix: String = "outbox pass"): String =
            "$prefix replayed=$replayed expired=$expired evicted=$evicted corrupt=$corrupt " +
                "identityMismatch=$identityMismatch bytesOnDisk=$bytesOnDisk"
    }

    companion object {
        private const val TAG = "TugboatOutbox"

        /** The engine's `jsonTimeoutMs` and `frameTimeoutMs`. */
        const val REPLAY_TIMEOUT_MS = 15_000

        /** The request's own deadline plus slack: its answer always comes before this. */
        private const val ANSWER_WAIT_MS = REPLAY_TIMEOUT_MS + 10_000L

        /** How long a pass waits for queued writes and wipes. */
        private const val AWAIT_QUEUED_MS = 5_000L

        fun newScheduler(): ScheduledExecutorService =
            ScheduledThreadPoolExecutor(1) { task ->
                Thread(task, "tugboat-outbox-replay").apply { isDaemon = true }
            }.apply { removeOnCancelPolicy = true }
    }
}
