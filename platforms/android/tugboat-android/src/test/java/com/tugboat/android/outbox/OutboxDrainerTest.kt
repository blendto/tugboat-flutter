package com.tugboat.android.outbox

import com.tugboat.android.host.FakeHttpSender
import com.tugboat.android.host.HttpExecutor
import com.tugboat.android.host.LocalHttpServer
import com.tugboat.android.host.LocalHttpServer.Response
import com.tugboat.android.host.MultipartParts
import com.tugboat.android.host.TransportOutcome
import com.tugboat.android.outbox.OutboxFixtures.awaitUntil
import com.tugboat.android.outbox.OutboxFixtures.entryDirs
import com.tugboat.android.outbox.OutboxFixtures.events
import com.tugboat.android.outbox.OutboxFixtures.frames
import com.tugboat.android.outbox.OutboxFixtures.hostConfig
import com.tugboat.android.outbox.OutboxFixtures.inputs
import com.tugboat.android.outbox.OutboxFixtures.jpeg
import com.tugboat.android.outbox.OutboxFixtures.lifecycle
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Replay (W11 design 3.3) against a real local server. A restart is two
 * [Outbox]es over one directory: process A writes, process B replays.
 */
@RunWith(RobolectricTestRunner::class)
class OutboxDrainerTest {
    private val root = OutboxFixtures.tempRoot()
    private val server = LocalHttpServer()
    private val logs = CopyOnWriteArrayList<String>()
    private val drainers = ArrayList<OutboxDrainer>()

    @After
    fun tearDown() {
        drainers.forEach(OutboxDrainer::stop)
        server.close()
        root.deleteRecursively()
    }

    /** Process A sends [requests]; none is answered before it dies. */
    private fun leftByADeadProcess(vararg requests: com.tugboat.android.host.HttpRequest, frameBytes: Map<String, ByteArray> = emptyMap()) {
        val a = OutboxFixtures.outbox(root, "epoch-a")
        val sender = OutboxSender(FakeHttpSender(), a, inputs, "0.1.0", frameBytes::get)
        requests.forEach { sender.send(it) {} }
        assertTrue(a.awaitQueued(5_000))
    }

    private fun drainer(
        outbox: Outbox,
        identity: OutboxIdentityInputs = inputs,
        scheduler: ScheduledThreadPoolExecutor = RecordingScheduler(),
    ): OutboxDrainer {
        val replay = HttpExecutor(hostConfig("http://127.0.0.1:${server.port}"), outbox.store::readFrame)
        return OutboxDrainer(outbox, identity, replay::perform, scheduler, replay::close) { logs += it }
            .also { drainers += it }
    }

    private fun passes(count: Int) = awaitUntil { logs.size >= count }

    private fun report(index: Int) = JSONObject(logs[index].removePrefix("outbox drain "))

    @Test
    fun anEntryLeftByADeadProcessIsReplayedOnceThenDeleted() {
        leftByADeadProcess(lifecycle(), events())
        val b = OutboxFixtures.outbox(root, "epoch-b")

        drainer(b).start()
        passes(1)

        assertEquals(setOf("/v1/sessions", "/v1/events/batch"), server.received.map { it.path }.toSet())
        val replayed = server.received.first { it.path == "/v1/sessions" }
        assertEquals("s-1/l/session_start/2026-10-27T10:00:00.000Z", replayed.headers["tugboat-delivery-key"])
        assertEquals("pmk_key", replayed.headers["x-tugboat-api-key"])
        assertEquals((lifecycle().body as com.tugboat.android.host.HttpBody.Json).text, replayed.body.toString(Charsets.UTF_8))
        assertEquals(2, report(0).getInt("replayed"))
        assertEquals(0L, report(0).getLong("bytesOnDisk"))
        assertTrue(entryDirs(root).isEmpty())

        // Another restart: nothing is left to send.
        drainer(OutboxFixtures.outbox(root, "epoch-c")).start()
        passes(2)
        assertEquals(2, server.received.size)
    }

    @Test
    fun aFrameEntryReplaysAsAOneFrameUpload() {
        leftByADeadProcess(frames("s-1", 7), frameBytes = mapOf("frame-7" to jpeg(7)))

        drainer(OutboxFixtures.outbox(root, "epoch-b")).start()
        passes(1)

        val request = server.received.single()
        assertEquals("/v1/frames", request.path)
        assertEquals("s-1/f/7", request.headers["tugboat-delivery-key"])
        val boundary = request.headers.getValue("content-type").substringAfter("boundary=")
        val parts = MultipartParts.parse(request.body, boundary)
        assertEquals(listOf("sessionId", "frameNos", "frameMetadata", "files"), parts.map { it.name })
        assertEquals(listOf("s-1", "7"), parts.take(2).map { it.text })
        assertEquals(7, org.json.JSONArray(parts[2].text).getJSONObject(0).getInt("atMs"))
        assertEquals("7.jpg", parts[3].filename)
        assertArrayEquals(jpeg(7), parts[3].bytes)
    }

    @Test
    fun anEntryOfAnotherKeyAppOrCollectorIsDeletedUnsent() {
        leftByADeadProcess(lifecycle())
        val rotated = OutboxIdentityInputs(inputs.collectorBaseUrl, inputs.appId, "pmk_rotated")

        drainer(OutboxFixtures.outbox(root, "epoch-b"), identity = rotated).start()
        passes(1)

        assertTrue(server.received.isEmpty())
        assertEquals(1, report(0).getInt("identityMismatch"))
        assertTrue(entryDirs(root).isEmpty())
    }

    @Test
    fun anEntryAtMaxAttemptsIsExpiredUnsent() {
        leftByADeadProcess(lifecycle())
        val b = OutboxFixtures.outbox(root, "epoch-b").apply {
            settings = OutboxSettings(1L shl 30, 1000, 1L shl 40, maxAttempts = 1)
        }

        drainer(b).start()
        passes(1)

        assertTrue(server.received.isEmpty())
        assertEquals(1, report(0).getInt("expired"))
        assertTrue(entryDirs(root).isEmpty())
    }

    @Test
    fun theCurrentSessionsEntriesWaitUntilTheNextSessionSends() {
        val outbox = OutboxFixtures.outbox(root, "epoch-a")
        val engine = FakeHttpSender()
        val sender = OutboxSender(engine, outbox, inputs, "0.1.0", frameBytes = { null })
        sender.send(events("s-1")) {}
        engine.complete(0, TransportOutcome.Http(503, ""))
        assertTrue(outbox.awaitQueued(5_000))

        drainer(outbox).start()
        passes(1)
        assertTrue("s-1 is the current session: the engine still owns it", server.received.isEmpty())

        // The engine evicted the batch; the next session's first send makes it an orphan.
        sender.send(lifecycle("s-2")) {}
        passes(2)
        assertEquals(listOf("/v1/events/batch"), server.received.map { it.path })
        assertEquals("s-2 is still in flight", 1, entryDirs(root).size)
    }

    @Test
    fun anOrphanWhoseRequestIsStillInFlightIsSkippedUntilItResolves() {
        val outbox = OutboxFixtures.outbox(root, "epoch-a")
        val engine = FakeHttpSender()
        val sender = OutboxSender(engine, outbox, inputs, "0.1.0", frameBytes = { null })
        sender.send(events("s-1")) {}
        val drainer = drainer(outbox)
        drainer.start()
        passes(1)

        // A new session while s-1's batch is still in flight.
        sender.send(lifecycle("s-2")) {}
        passes(2)
        assertTrue(server.received.isEmpty())

        engine.complete(0, TransportOutcome.Timeout)
        sender.send(lifecycle("s-3")) {}
        passes(3)
        assertEquals(listOf("/v1/events/batch"), server.received.map { it.path })
    }

    @Test
    fun aRetriedReplayCountsTheAttemptAndBacksOffAsRetryAfterAsks() {
        leftByADeadProcess(lifecycle())
        server.reply = { Response(503, "", mapOf("Retry-After" to "120")) }
        val scheduler = RecordingScheduler()

        drainer(OutboxFixtures.outbox(root, "epoch-b"), scheduler = scheduler).start()
        passes(1)

        assertEquals(1, server.received.size)
        assertEquals(listOf(0L, 120_000L), scheduler.delays)
        assertTrue("the entry is still on disk", report(0).getLong("bytesOnDisk") > 0)
        assertEquals(2, JSONObject(File(entryDirs(root).single(), "entry.json").readText()).getInt("attempts"))
    }

    @Test
    fun anEngineRequestStartsAtOnceWhileAReplayIsInFlight() {
        leftByADeadProcess(lifecycle())
        val replayArrived = CountDownLatch(1)
        val releaseReplay = CountDownLatch(1)
        server.reply = {
            replayArrived.countDown()
            releaseReplay.await(10, TimeUnit.SECONDS)
            Response(202)
        }
        val engineServer = LocalHttpServer()
        // The warm-up request, then the measured one.
        val engineArrived = CountDownLatch(2)
        engineServer.reply = {
            engineArrived.countDown()
            Response(202)
        }
        val drainerScheduler = OutboxDrainer.newScheduler() as ScheduledThreadPoolExecutor
        val engineHttp = HttpExecutor(hostConfig("http://127.0.0.1:${engineServer.port}"), { null })
        try {
            // Warm the engine path so the measurement is the queueing, not class loading.
            engineHttp.perform(lifecycle())
            drainer(OutboxFixtures.outbox(root, "epoch-b"), scheduler = drainerScheduler).start()
            assertTrue(replayArrived.await(5, TimeUnit.SECONDS))

            val sentAt = System.nanoTime()
            engineHttp.send(lifecycle("s-2")) {}
            val started = engineArrived.await(2, TimeUnit.SECONDS)
            val elapsedMs = (System.nanoTime() - sentAt) / 1_000_000

            assertTrue("the engine request waited behind the replay", started)
            assertTrue("started after $elapsedMs ms", elapsedMs < 50)
        } finally {
            releaseReplay.countDown()
            engineHttp.close()
            engineServer.close()
        }
    }

    /** Records each pass's delay, running them as usual. */
    private class RecordingScheduler : ScheduledThreadPoolExecutor(1) {
        val delays = CopyOnWriteArrayList<Long>()

        override fun schedule(command: Runnable, delay: Long, unit: TimeUnit): ScheduledFuture<*> {
            delays += unit.toMillis(delay)
            return super.schedule(command, delay, unit)
        }
    }
}
