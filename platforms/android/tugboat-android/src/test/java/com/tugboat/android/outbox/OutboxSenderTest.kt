package com.tugboat.android.outbox

import com.tugboat.android.host.FakeHttpSender
import com.tugboat.android.host.HttpBody
import com.tugboat.android.host.TransportOutcome
import com.tugboat.android.outbox.OutboxFixtures.entryDirs
import com.tugboat.android.outbox.OutboxFixtures.events
import com.tugboat.android.outbox.OutboxFixtures.frames
import com.tugboat.android.outbox.OutboxFixtures.inputs
import com.tugboat.android.outbox.OutboxFixtures.jpeg
import com.tugboat.android.outbox.OutboxFixtures.lifecycle
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** The engine path (W11 design 3.2): write at dispatch, delete on an answer that ends the request. */
@RunWith(RobolectricTestRunner::class)
class OutboxSenderTest {
    private val root = OutboxFixtures.tempRoot()
    private val outbox = OutboxFixtures.outbox(root, "epoch-a")
    private val http = FakeHttpSender()
    private val frameBytes = HashMap<String, ByteArray>()
    private val sender = OutboxSender(http, outbox, inputs, "0.1.0", frameBytes::get)
    private val answers = ArrayList<TransportOutcome>()

    @After
    fun tearDown() {
        root.deleteRecursively()
    }

    private fun settled() = assertTrue(outbox.awaitQueued(5_000))

    private fun entry(dir: File) = JSONObject(File(dir, "entry.json").readText())

    @Test
    fun aSentRequestIsKeptUntilTheCollectorAcceptsItAndCarriesItsKey() {
        sender.send(lifecycle()) { answers += it }
        settled()

        val dir = entryDirs(root).single()
        val stored = entry(dir)
        assertEquals("s-1/l/session_start/2026-10-27T10:00:00.000Z", stored.getString("key"))
        assertEquals(1, stored.getInt("v"))
        assertEquals(1, stored.getInt("attempts"))
        assertEquals("epoch-a", stored.getString("processEpoch"))
        assertTrue("never the raw key", "pmk_key" !in File(dir, "entry.json").readText())
        assertEquals((lifecycle().body as HttpBody.Json).text, File(dir, "body").readText())
        assertEquals("s-1/l/session_start/2026-10-27T10:00:00.000Z", http.requests.single().headers["Tugboat-Delivery-Key"])

        http.complete(0, TransportOutcome.Http(202, "{}"))
        settled()
        assertEquals("the engine still gets its answer", 1, answers.size)
        assertTrue(entryDirs(root).isEmpty())
    }

    @Test
    fun aRetriedAnswerKeepsTheEntryAndADroppedOneDeletesIt() {
        sender.send(events()) {}
        http.complete(0, TransportOutcome.Http(503, ""))
        sender.send(events()) {}
        http.complete(1, TransportOutcome.Timeout)
        settled()
        assertEquals(2, entry(entryDirs(root).single()).getInt("attempts"))

        sender.send(events()) {}
        http.complete(2, TransportOutcome.Http(400, "{}"))
        settled()
        assertTrue("a status the engine does not retry ends the entry", entryDirs(root).isEmpty())
    }

    @Test
    fun aLateAcceptForAnEarlierAttemptDoesNotDeleteWhileALaterOneIsInFlight() {
        sender.send(events()) {}
        settled()
        // The engine gave up on attempt 1 (its answer deadline) and sent attempt 2.
        sender.send(events()) {}
        http.complete(0, TransportOutcome.Http(202, "{}"))
        settled()
        assertEquals("attempt 2 is in flight", 1, entryDirs(root).size)

        http.complete(1, TransportOutcome.Http(202, "{}"))
        settled()
        assertTrue(entryDirs(root).isEmpty())
    }

    @Test
    fun aRetriedLifecyclePostKeepsItsLastBody() {
        sender.send(lifecycle(userId = "u-1")) {}
        http.complete(0, TransportOutcome.Http(503, ""))
        sender.send(lifecycle(userId = "u-2")) {}
        settled()

        val dir = entryDirs(root).single()
        assertEquals("u-2", JSONObject(File(dir, "body").readText()).getString("userId"))
        assertEquals(2, entry(dir).getInt("attempts"))
    }

    @Test
    fun aFrameIsWrittenOnceAndALaterChunkOnlyCountsTheAttempt() {
        frameBytes["frame-1"] = jpeg(1)
        frameBytes["frame-2"] = jpeg(2)
        sender.send(frames("s-1", 1, 2)) {}
        http.complete(0, TransportOutcome.Http(503, ""))
        settled()
        assertEquals(2, entryDirs(root).size)
        assertEquals("s-1/f/1,s-1/f/2", http.requests[0].headers["Tugboat-Delivery-Key"])

        // The chunk re-forms with frame 2 and a new frame 3; frame 2's bytes are not written again.
        frameBytes["frame-2"] = jpeg(99)
        frameBytes["frame-3"] = jpeg(3)
        sender.send(frames("s-1", 2, 3)) {}
        settled()

        val byKey = entryDirs(root).associateBy { entry(it).getString("key") }
        assertEquals(setOf("s-1/f/1", "s-1/f/2", "s-1/f/3"), byKey.keys)
        val two = byKey.getValue("s-1/f/2")
        assertArrayEquals(jpeg(2), File(two, "frame.jpg").readBytes())
        assertEquals(2, entry(two).getInt("attempts"))
        val fields = JSONObject(File(two, "fields.json").readText())
        assertEquals("2", fields.getString("frameNo"))
        assertEquals(2, fields.getJSONObject("metadata").getInt("atMs"))
    }

    @Test
    fun aRequestWithoutAKeyIsSentAsBeforeWithoutAnEntry() {
        val unkeyed = lifecycle().copy(body = HttpBody.Json("""{"eventType":"session_start"}"""))
        sender.send(unkeyed) { answers += it }
        settled()

        assertNull(http.requests.single().headers["Tugboat-Delivery-Key"])
        assertTrue(entryDirs(root).isEmpty())
        assertEquals(1, outbox.unkeyed.get())
        http.complete(0, TransportOutcome.Http(202, "{}"))
        assertEquals(1, answers.size)
    }

    @Test
    fun aDiskThatCannotBeWrittenStillDeliversAndCountsTheFailure() {
        // The outbox root is a file: every write fails.
        val blocked = File(root, "blocked").apply { writeText("x") }
        val broken = OutboxFixtures.outbox(blocked, "epoch-a")
        val brokenSender = OutboxSender(http, broken, inputs, "0.1.0", frameBytes::get)

        brokenSender.send(lifecycle()) { answers += it }
        assertTrue(broken.awaitQueued(5_000))

        assertEquals(1, http.requests.size)
        assertEquals(1, broken.writeFailures.get())
        assertEquals("the request is sent unchanged but for its key", lifecycle().body, http.requests.single().body)
        http.complete(0, TransportOutcome.Http(202, "{}"))
        assertEquals(1, answers.size)
    }

    @Test
    fun aSenderFromBeforeAWipeStillSendsButWritesNothingMore() {
        // The engine of a stopped session is still draining when the app clears the outbox.
        outbox.wipe()
        sender.send(lifecycle(eventType = "session_end")) { answers += it }
        settled()

        assertEquals("still sent", 1, http.requests.size)
        assertNull(http.requests.single().headers["Tugboat-Delivery-Key"])
        assertTrue(entryDirs(root).isEmpty())

        // A sender of the next session records again.
        OutboxSender(http, outbox, inputs, "0.1.0", frameBytes::get).send(lifecycle("s-2")) {}
        settled()
        assertEquals(1, entryDirs(root).size)
    }

    @Test
    fun aWriteQueuedJustAfterAWipeByAnOlderSenderLandsNothing() {
        val older = outbox.registerSender()
        // The sender checked its generation, then the wipe ran, then its write was queued.
        outbox.wipe()
        outbox.write(OutboxKeys.capture(lifecycle()) { null }.orEmpty(), inputs, "0.1.0", older)
        settled()

        assertTrue(entryDirs(root).isEmpty())
    }

    @Test
    fun anEngineRequestStartsAtOnceWhileTheDiskIsBusy() {
        val release = CountDownLatch(1)
        val busyIo = java.util.concurrent.Executors.newSingleThreadExecutor()
        busyIo.execute { release.await(30, TimeUnit.SECONDS) }
        val busy = Outbox(root = { root }, processEpoch = "epoch-a", io = busyIo)
        val busySender = OutboxSender(http, busy, inputs, "0.1.0", frameBytes::get)
        try {
            val returned = CountDownLatch(1)
            Thread {
                busySender.send(lifecycle()) {}
                returned.countDown()
            }.start()

            // The disk stays held for 30 s: a send that waited for it would not return in time.
            assertTrue("the send waited for the disk", returned.await(2, TimeUnit.SECONDS))
            assertEquals(1, http.requests.size)
            assertTrue("the write is still queued", entryDirs(root).isEmpty())
        } finally {
            release.countDown()
            busyIo.shutdown()
        }
    }

    @Test
    fun aReplacedSessionsLateSendNeverMovesTheCurrentSessionBack() {
        val oldSender = sender
        val newSender = OutboxSender(http, outbox, inputs, "0.1.0", frameBytes::get)
        newSender.send(events("s-2")) {}
        http.complete(0, TransportOutcome.Http(503, ""))
        // The replaced session's session_end is still retrying.
        oldSender.send(lifecycle("s-1", eventType = "session_end")) {}
        settled()

        assertEquals("s-2", outbox.currentSession)
        val live = outbox.scanAndEvict().entries.single { it.sessionId == "s-2" }
        assertTrue("the live session's batch stays the engine's", !outbox.isOrphan(live))
    }

    @Test
    fun closeLetsQueuedWritesLandBeforeTheExecutorCloses() {
        val release = CountDownLatch(1)
        val slowIo = java.util.concurrent.Executors.newSingleThreadExecutor()
        slowIo.execute { release.await(5, TimeUnit.SECONDS) }
        val slow = Outbox(root = { root }, processEpoch = "epoch-a", io = slowIo)
        var entriesAtClose = -1
        val closing = object : com.tugboat.android.host.HttpSender {
            override fun send(
                request: com.tugboat.android.host.HttpRequest,
                onResult: (TransportOutcome) -> Unit,
            ) = Unit

            override fun close() {
                entriesAtClose = entryDirs(root).size
            }
        }
        val slowSender = OutboxSender(closing, slow, inputs, "0.1.0", frameBytes::get)
        slowSender.send(lifecycle()) {}
        Thread { Thread.sleep(200); release.countDown() }.start()

        slowSender.close()

        assertEquals("the write landed before the executor closed", 1, entriesAtClose)
        slowIo.shutdown()
    }
}
