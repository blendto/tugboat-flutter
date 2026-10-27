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
import org.junit.Assume.assumeFalse
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
        return OutboxDrainer(outbox, identity, replay::send, scheduler, replay::close) { logs += it }
            .also { drainers += it }
    }

    private fun passes(count: Int) = awaitUntil { logs.size >= count }

    /** The `outbox pass k=v …` line of pass [index]. */
    private fun report(index: Int): Map<String, Long> =
        logs[index].removePrefix("outbox pass ").split(' ').associate { it.substringBefore('=') to it.substringAfter('=').toLong() }

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
        assertEquals(2, report(0).getValue("replayed").toInt())
        assertEquals(0L, report(0).getValue("bytesOnDisk"))
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
        assertEquals(1, report(0).getValue("identityMismatch").toInt())
        assertTrue(entryDirs(root).isEmpty())
    }

    private fun editEntry(edit: (JSONObject) -> Unit) {
        val file = File(entryDirs(root).single(), "entry.json")
        file.writeText(JSONObject(file.readText()).also(edit).toString())
    }

    private fun entryJson() = JSONObject(File(entryDirs(root).single(), "entry.json").readText())

    @Test
    fun anEntryReplayedMaxAttemptsTimesIsExpiredUnsent() {
        leftByADeadProcess(lifecycle())
        editEntry { it.put("replays", 8) }

        drainer(OutboxFixtures.outbox(root, "epoch-b")).start()
        passes(1)

        assertTrue("sent anyway: ${server.received.size}", server.received.isEmpty())
        assertEquals(1, report(0).getValue("expired").toInt())
        assertTrue(entryDirs(root).isEmpty())
    }

    @Test
    fun anEntryTheEngineRetriedThroughAnOutageIsStillReplayedAfterAKill() {
        // Offline for about 25 s: the engine re-sent the lifecycle head 8 times, all errors; then the app was killed.
        val a = OutboxFixtures.outbox(root, "epoch-a")
        val engine = FakeHttpSender()
        val sender = OutboxSender(engine, a, inputs, "0.1.0", frameBytes = { null })
        repeat(8) { index ->
            sender.send(lifecycle()) {}
            engine.complete(index, TransportOutcome.Error)
        }
        assertTrue(a.awaitQueued(5_000))
        assertEquals(8, entryJson().getInt("attempts"))

        drainer(OutboxFixtures.outbox(root, "epoch-b")).start()
        passes(1)

        assertEquals("the online relaunch sends it", 1, server.received.size)
        assertTrue(entryDirs(root).isEmpty())
    }

    @Test
    fun theBackoffCountsReplaysNotTheEnginesAttempts() {
        leftByADeadProcess(lifecycle())
        editEntry { it.put("attempts", 40) }
        server.reply = { Response(503) }
        val scheduler = RecordingScheduler()

        drainer(OutboxFixtures.outbox(root, "epoch-b"), scheduler = scheduler).start()
        passes(1)

        assertEquals("first replay: the 2 s step", listOf(0L, 2_000L), scheduler.delays)
        assertEquals(1, entryJson().getInt("replays"))
    }

    @Test
    fun replaysGoOldestFirstEvenWhenTheKeysSortTheOtherWay() {
        var now = System.currentTimeMillis() - 10_000
        val a = OutboxFixtures.outbox(root, "epoch-a") { now }
        val sender = OutboxSender(FakeHttpSender(), a, inputs, "0.1.0", frameBytes = { null })
        // "s-1/l/…" sorts after "s-1/e/…", but was written first.
        sender.send(lifecycle()) {}
        assertTrue(a.awaitQueued(5_000))
        now += 1_000
        sender.send(events()) {}
        assertTrue(a.awaitQueued(5_000))

        drainer(OutboxFixtures.outbox(root, "epoch-b")).start()
        passes(1)

        assertEquals(listOf("/v1/sessions", "/v1/events/batch"), server.received.map { it.path })
    }

    @Test
    fun aPayloadThatCannotBeReadIsSkippedNotDeleted() {
        leftByADeadProcess(lifecycle())
        val body = File(entryDirs(root).single(), "body").apply { setReadable(false) }
        assumeFalse("running as root: every file is readable", body.canRead())
        val b = OutboxFixtures.outbox(root, "epoch-b")
        try {
            drainer(b).start()
            passes(1)
            assertTrue(server.received.isEmpty())
            assertEquals("kept", 1, entryDirs(root).size)
        } finally {
            body.setReadable(true)
        }

        drainer(b).start()
        passes(2)
        assertEquals(1, server.received.size)
    }

    @Test
    fun noReplayStartsAfterStopReturns() {
        leftByADeadProcess(lifecycle())
        val sends = CopyOnWriteArrayList<String>()
        val atSend = CountDownLatch(1)
        val stopped = CountDownLatch(1)
        val drainer = OutboxDrainer(
            OutboxFixtures.outbox(root, "epoch-b"), inputs, { request, _ -> sends += request.path },
            log = { logs += it },
        ).also { drainers += it }
        drainer.beforeSendForTesting = {
            atSend.countDown()
            // stop() interrupts this thread; hold on until it has returned regardless.
            while (stopped.count > 0) {
                try {
                    stopped.await(5, TimeUnit.SECONDS)
                } catch (_: InterruptedException) {
                    // Keep waiting.
                }
            }
        }

        drainer.start()
        assertTrue(atSend.await(5, TimeUnit.SECONDS))
        drainer.stop()
        stopped.countDown()
        Thread.sleep(300)

        assertTrue("a replay started after stop() returned", sends.isEmpty())
    }

    @Test
    fun replaysThatNeverStartedDoNotUseUpTheBudget() {
        leftByADeadProcess(lifecycle())
        val b = OutboxFixtures.outbox(root, "epoch-b")
        // Eight sessions, each stopped just as its replay would start.
        repeat(8) {
            val passDone = CountDownLatch(1)
            val replay = HttpExecutor(hostConfig("http://127.0.0.1:${server.port}"), b.store::readFrame)
            lateinit var quick: OutboxDrainer
            quick = OutboxDrainer(b, inputs, replay::send, onStop = replay::close, log = { passDone.countDown() })
            quick.beforeSendForTesting = { quick.stop() }
            quick.start()
            assertTrue(passDone.await(5, TimeUnit.SECONDS))
        }
        assertTrue(server.received.isEmpty())

        drainer(b).start()
        passes(1)
        assertEquals("the next session still replays it", 1, server.received.size)
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
        assertTrue("the entry is still on disk", report(0).getValue("bytesOnDisk") > 0)
        assertEquals(2, JSONObject(File(entryDirs(root).single(), "entry.json").readText()).getInt("attempts"))
    }

    @Test
    fun anEngineRequestStartsAtOnceWhileAReplayIsInFlight() {
        leftByADeadProcess(lifecycle())
        val replayArrived = CountDownLatch(1)
        val releaseReplay = CountDownLatch(1)
        server.reply = {
            replayArrived.countDown()
            releaseReplay.await(30, TimeUnit.SECONDS)
            Response(202)
        }
        val engineServer = LocalHttpServer()
        val engineArrived = CountDownLatch(1)
        // Ordering, not wall-clock: the engine request must reach the server
        // while the replay is still held there. Behind the replay it would
        // only arrive after the release.
        val replayHeldOnArrival = CopyOnWriteArrayList<Boolean>()
        engineServer.reply = {
            replayHeldOnArrival += releaseReplay.count == 1L
            engineArrived.countDown()
            Response(202)
        }
        val drainerScheduler = OutboxDrainer.newScheduler() as ScheduledThreadPoolExecutor
        val engineHttp = HttpExecutor(hostConfig("http://127.0.0.1:${engineServer.port}"), { null })
        try {
            drainer(OutboxFixtures.outbox(root, "epoch-b"), scheduler = drainerScheduler).start()
            assertTrue(replayArrived.await(5, TimeUnit.SECONDS))

            engineHttp.send(lifecycle("s-2")) {}

            assertTrue("the engine request waited behind the replay", engineArrived.await(10, TimeUnit.SECONDS))
            assertEquals(listOf(true), replayHeldOnArrival)
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
