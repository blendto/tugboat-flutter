package com.tugboat.android.outbox

import android.util.Log
import com.tugboat.android.host.FramePart
import com.tugboat.android.host.HttpBody
import com.tugboat.android.host.HttpRequest
import com.tugboat.android.host.TransportOutcome
import com.tugboat.android.sdk.SessionEndWatcher
import org.json.JSONObject
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * Replays orphaned outbox entries (W11 design 3.3) on its own thread, one
 * request at a time, beside the engine's one: never on the engine's IO
 * thread, where a replay would hold engine requests past their answer
 * deadline. One drainer per running session: it starts after `session.start`
 * is posted and stops with the session, so nothing is sent while dormant.
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
    /** Performs one request on the calling thread; normally `HttpExecutor.perform` over [OutboxStore.readFrame]. */
    private val perform: (HttpRequest) -> TransportOutcome,
    private val scheduler: ScheduledExecutorService = newScheduler(),
    /** Runs at [stop]; closes what [perform] uses. */
    private val onStop: () -> Unit = {},
    private val log: (String) -> Unit = { line -> Log.i(TAG, line) },
) {
    @Volatile
    private var stopped = false
    private var pending: ScheduledFuture<*>? = null
    private val onSessionChanged: () -> Unit = { request(0) }

    fun start() {
        outbox.addSessionListener(onSessionChanged)
        request(0)
    }

    /** No pass starts after this; one already sending finishes its request (bounded by its timeout). */
    fun stop() {
        stopped = true
        outbox.removeSessionListener(onSessionChanged)
        synchronized(this) { pending?.cancel(false) }
        try {
            scheduler.shutdownNow()
            onStop()
        } catch (failure: Throwable) {
            Log.w(TAG, "outbox drainer stop failed: ${failure.javaClass.simpleName}")
        }
    }

    /** Schedules a pass in [delayMs], unless one is already due sooner. */
    private fun request(delayMs: Long) = synchronized(this) {
        if (stopped) return@synchronized
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
        if (stopped) return
        // Wipes and writes queued before this pass land first.
        outbox.awaitQueued(AWAIT_QUEUED_MS)
        val scan = outbox.scanAndEvict()
        val report = PassReport(expired = scan.expired, corrupt = scan.corrupt)
        val identity = outbox.identity.of(inputs)
        var retryInMs: Long? = null
        if (identity != null) {
            for (entry in scan.entries.sortedWith(compareBy<StoredEntry> { it.createdAtWallMs }.thenBy { it.key })) {
                if (stopped) break
                if (!outbox.isOrphan(entry) || outbox.active.isActive(entry.key)) {
                    report.bytesOnDisk += entry.bytes
                    continue
                }
                retryInMs = replay(entry, identity, report)
                if (retryInMs != null) break
            }
        }
        report.evicted = outbox.evicted.getAndSet(0)
        log(report.line())
        retryInMs?.let(::request)
    }

    /** Sends [entry] once; null to go on with the pass, else the delay before the next one. */
    private fun replay(entry: StoredEntry, identity: String, report: PassReport): Long? {
        when {
            entry.appIdentity != identity -> report.identityMismatch += deleted(entry)
            entry.attempts >= outbox.settings.maxAttempts -> report.expired += deleted(entry)
            else -> return send(entry, report)
        }
        return null
    }

    private fun send(entry: StoredEntry, report: PassReport): Long? {
        val request = requestFor(entry) ?: run {
            report.corrupt += deleted(entry)
            return null
        }
        val attempt = outbox.active.begin(entry.key)
        val outcome = try {
            // Counted before the send: a crash mid-send still uses up an attempt.
            if (!outbox.store.recordAttempt(entry, outbox.wallMs())) return null
            perform(request)
        } finally {
            outbox.active.end(entry.key, attempt)
        }
        if (!SessionEndWatcher.isFinal(outcome)) {
            report.bytesOnDisk += entry.bytes
            val retryAfter = (outcome as? TransportOutcome.Http)?.retryAfter
            return OutboxBackoff.delayMs(entry.attempts + 1, retryAfter, outbox.wallMs())
        }
        if (!outbox.active.hasNewer(entry.key, attempt)) outbox.store.delete(entry.dirName)
        if ((outcome as? TransportOutcome.Http)?.status == ACCEPTED) report.replayed++ else report.dropped++
        return null
    }

    private fun deleted(entry: StoredEntry): Int = if (outbox.store.delete(entry.dirName)) 1 else 0

    private fun requestFor(entry: StoredEntry): HttpRequest? {
        val body = when (entry.lane) {
            OutboxLane.FRAMES -> {
                val fields = outbox.store.readFields(entry.dirName)?.let(OutboxKeys::frameFields) ?: return null
                val frameNo = fields.firstOrNull { it.first == OutboxKeys.FRAMES_FIELD_NUMBERS }?.second ?: return null
                // The frame handle is the entry directory: [OutboxStore.readFrame] resolves it at send time.
                HttpBody.Multipart(fields, listOf(FramePart(entry.dirName, "$frameNo.jpg")))
            }
            else -> HttpBody.Json(String(outbox.store.readBody(entry.dirName) ?: return null, Charsets.UTF_8))
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

    /** One pass's counts: the `TugboatOutbox` log line. */
    class PassReport(var expired: Int = 0, var corrupt: Int = 0) {
        var replayed = 0
        var dropped = 0
        var evicted = 0
        var identityMismatch = 0
        var bytesOnDisk = 0L

        fun line(): String = "outbox drain " + JSONObject()
            .put("replayed", replayed)
            .put("dropped", dropped)
            .put("expired", expired)
            .put("evicted", evicted)
            .put("corrupt", corrupt)
            .put("identityMismatch", identityMismatch)
            .put("bytesOnDisk", bytesOnDisk)
            .toString()
    }

    companion object {
        private const val TAG = "TugboatOutbox"
        private const val ACCEPTED = 202

        /** The engine's `jsonTimeoutMs` and `frameTimeoutMs`. */
        const val REPLAY_TIMEOUT_MS = 15_000

        /** How long a pass waits for queued writes and wipes. */
        private const val AWAIT_QUEUED_MS = 5_000L

        fun newScheduler(): ScheduledExecutorService =
            ScheduledThreadPoolExecutor(1) { task ->
                Thread(task, "tugboat-outbox-replay").apply { isDaemon = true }
            }.apply { removeOnCancelPolicy = true }
    }
}
