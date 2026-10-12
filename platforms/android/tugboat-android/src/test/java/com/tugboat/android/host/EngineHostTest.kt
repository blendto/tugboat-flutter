package com.tugboat.android.host

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.tugboat.android.engine.EngineStatus
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.time.Duration

/** Drives [EngineHost] on the paused Robolectric main looper as its engine thread. */
@RunWith(RobolectricTestRunner::class)
class EngineHostTest {
    private val looper = shadowOf(Looper.getMainLooper())
    private val clock = FakeClock()
    private val frames = FrameHandleTable()
    private val transport = FakeEngineTransport()
    private val http = FakeHttpSender(frames)
    private var shutDowns = 0
    private val host = EngineHost(
        transport = transport,
        handler = Handler(Looper.getMainLooper()),
        http = http,
        frames = frames,
        clock = clock,
        onShutDown = { shutDowns++ },
    )

    private val factAt = HostTime(monoUs = 5_000, wallUs = 7_000)
    private val factAtJson = """"at":{"monoUs":5000,"wallUs":7000}"""

    /** `engine.dispose` stamped by the fake clock at shutdown. */
    private val dispose = """{"type":"engine.dispose","at":{"monoUs":1000000,"wallUs":1791712345678901},"input":{}}"""

    private fun post(type: String, frameHandles: List<String> = emptyList()) =
        host.post(type, "{}", factAt, frameHandles)

    @Test
    fun postsAreSubmittedInOrderOnTheEngineThread() {
        post("a")
        host.postUntimed("engine.configure", """{"k":1.0}""")
        post("c")
        assertEquals("nothing runs on the caller's thread", 0, transport.submitted.size)

        looper.idle()
        assertEquals(
            listOf(
                """{"type":"a",$factAtJson,"input":{}}""",
                """{"type":"engine.configure","input":{"k":1.0}}""",
                """{"type":"c",$factAtJson,"input":{}}""",
            ),
            transport.submitted,
        )
        assertTrue(transport.submitThreads.all { it == Looper.getMainLooper().thread })
    }

    @Test
    fun postsFromManyThreadsAreSerialized() {
        val threads = (0 until 4).map { t ->
            Thread { repeat(25) { i -> host.post("t$t", """{"i":$i}""", factAt) } }
        }
        threads.forEach(Thread::start)
        threads.forEach(Thread::join)
        looper.idle()

        assertEquals(100, transport.submitted.size)
        assertEquals(0, transport.overlappingSubmits)
        for (t in 0 until 4) {
            val order = transport.submitted.filter { "\"t$t\"" in it }
                .map { JSONObject(it).getJSONObject("input").getInt("i") }
            assertEquals("thread $t keeps its own order", (0 until 25).toList(), order)
        }
    }

    @Test
    fun batchesKeepEachMessagesOwnTime() {
        host.postBatch(
            listOf(
                EngineMessage("a", "{}", factAt),
                EngineMessage("b", "{}", HostTime(6_000, 8_000)),
            ),
        )
        host.postBatch(emptyList())
        looper.idle()

        assertEquals(
            listOf(
                """{"type":"batch","messages":[{"type":"a",$factAtJson,"input":{}},""" +
                    """{"type":"b","at":{"monoUs":6000,"wallUs":8000},"input":{}}]}""",
            ),
            transport.submitted,
        )
    }

    @Test
    fun effectsRunInResponseOrder() {
        val handle = frames.put(byteArrayOf(1))
        val upload = """{"type":"http.send","requestId":"http-1","lane":"frames","path":"/v1/frames","timeoutMs":1,""" +
            """"multipart":{"fields":[],"frames":[{"handle":"$handle","filename":"1.jpg"}]}}"""
        val release = """{"type":"frame.release","handle":"$handle"}"""
        transport.enqueue(ok(upload, release))
        transport.enqueue(ok(release, upload))

        post("first")
        post("second")
        looper.idle()

        assertEquals(listOf(true, false), http.framesPresentAtSend)
    }

    @Test
    fun timerEffectsScheduleReplaceCancelAndFire() {
        val now = SystemClock.uptimeMillis()
        transport.enqueue(
            ok(
                """{"type":"timer.schedule","timerId":"flush","atMonoUs":${(now + 100) * 1000}}""",
                """{"type":"timer.schedule","timerId":"debounce","atMonoUs":${(now + 50) * 1000}}""",
                """{"type":"timer.schedule","timerId":"flush","atMonoUs":${(now + 300) * 1000}}""",
                """{"type":"timer.cancel","timerId":"debounce"}""",
            ),
        )
        post("session.start")
        looper.idle()

        looper.idleFor(Duration.ofMillis(299))
        assertEquals(1, transport.submitted.size)
        clock.monoUs = (now + 300) * 1000
        looper.idleFor(Duration.ofMillis(1))
        assertEquals(
            """{"type":"timer.fired","at":{"monoUs":${(now + 300) * 1000},"wallUs":1791712345678901},""" +
                """"input":{"timerId":"flush"}}""",
            transport.submitted.last(),
        )
        looper.idleFor(Duration.ofSeconds(5))
        assertEquals(2, transport.submitted.size)
    }

    @Test
    fun transportResultsComeBackThroughTheEngineThread() {
        transport.enqueue(
            ok(
                """{"type":"http.send","requestId":"http-42","lane":"events","path":"/v1/events/batch",""" +
                    """"timeoutMs":15000,"jsonBody":"{\"a\":1.0}"}""",
            ),
        )
        post("flush")
        looper.idle()
        assertEquals(HttpBody.Json("{\"a\":1.0}"), http.requests.single().body)

        clock.monoUs = 2_000_000
        val io = Thread { http.complete(0, TransportOutcome.Http(202, "{\"sessionId\":\"s\"}")) }
        io.start()
        io.join()
        assertEquals("not submitted from the IO thread", 1, transport.submitted.size)
        looper.idle()

        val result = JSONObject(transport.submitted.last())
        assertEquals("transport.result", result.getString("type"))
        assertEquals("stamped when the result arrived", 2_000_000L, result.getJSONObject("at").getLong("monoUs"))
        assertEquals("http-42", result.getJSONObject("input").getString("requestId"))
        assertEquals(202, result.getJSONObject("input").getInt("status"))
    }

    @Test
    fun rejectedMessagesAreDroppedAndTheirFramesReleased() {
        val rejected = frames.put(byteArrayOf(1))
        val accepted = frames.put(byteArrayOf(2))
        transport.enqueue(failure(EngineStatus.INVALID_MESSAGE))

        post("bad", listOf(rejected))
        post("good", listOf(accepted))
        looper.idle()

        assertEquals(2, transport.submitted.size)
        assertNull("the engine never owned it", frames[rejected])
        assertNotNull("the engine owns it until frame.release", frames[accepted])
        assertTrue(host.isRunning)
    }

    @Test
    fun aRejectedBatchReleasesEveryMessagesFrames() {
        val handles = (1..3).map { frames.put(byteArrayOf(it.toByte())) }
        transport.enqueue(failure(EngineStatus.INVALID_MESSAGE))

        host.postBatch(
            listOf(
                EngineMessage("a", "{}", factAt, handles.take(2)),
                EngineMessage("b", "{}", factAt),
                EngineMessage("c", "{}", factAt, handles.drop(2)),
            ),
        )
        looper.idle()

        assertEquals(0, frames.size)
    }

    @Test
    fun framesOfMessagesThatNeverReachTheEngineAreReleased() {
        transport.throwOnSubmit = OutOfMemoryError("engine")
        val thrown = frames.put(byteArrayOf(1))
        post("a", listOf(thrown))
        looper.idle()
        assertNull(frames[thrown])

        transport.throwOnSubmit = null
        val queued = frames.put(byteArrayOf(2))
        post("queued", listOf(queued))
        host.close()
        val late = frames.put(byteArrayOf(3))
        post("late", listOf(late))
        looper.idle()

        assertEquals(0, frames.size)
        assertNull("put after shutdown keeps nothing", frames[frames.put(byteArrayOf(4))])
    }

    @Test
    fun consecutiveInternalErrorsDisableTheHost() {
        frames.put(byteArrayOf(1))
        transport.enqueue(ok("""{"type":"timer.schedule","timerId":"t","atMonoUs":${(SystemClock.uptimeMillis() + 10) * 1000}}"""))
        repeat(EngineHost.DEFAULT_MAX_CONSECUTIVE_INTERNAL_ERRORS) { transport.enqueue(failure(EngineStatus.INTERNAL_ERROR)) }

        repeat(1 + EngineHost.DEFAULT_MAX_CONSECUTIVE_INTERNAL_ERRORS) { post("m$it") }
        val queuedBeforeDisable = frames.put(byteArrayOf(2))
        post("queuedBeforeDisable", listOf(queuedBeforeDisable))
        looper.idle()
        post("afterDisable")
        looper.idleFor(Duration.ofSeconds(1))

        assertEquals(2 + EngineHost.DEFAULT_MAX_CONSECUTIVE_INTERNAL_ERRORS, transport.submitted.size)
        assertEquals("disabling disposes the engine too", dispose, transport.submitted.last())
        assertEquals(transport.submitted.size, transport.submittedAtClose)
        assertFalse(host.isRunning)
        assertTrue(transport.closed)
        assertTrue(http.closed)
        assertEquals(0, frames.size)
        assertEquals(1, shutDowns)
    }

    @Test
    fun otherStatusesResetTheInternalErrorStreak() {
        listOf(EngineStatus.INTERNAL_ERROR, EngineStatus.INTERNAL_ERROR, EngineStatus.INVALID_MESSAGE)
            .forEach { transport.enqueue(failure(it)) }
        transport.enqueue(failure(EngineStatus.INTERNAL_ERROR))
        transport.enqueue(failure(EngineStatus.INTERNAL_ERROR))

        repeat(5) { post("m$it") }
        looper.idle()

        assertTrue(host.isRunning)
        assertFalse(transport.closed)
    }

    @Test
    fun throwablesNeverEscapeTheEngineThread() {
        transport.throwOnSubmit = StackOverflowError("boom")
        post("a")
        looper.idle()
        transport.throwOnSubmit = null
        post("b")
        looper.idle()

        assertEquals(2, transport.submitted.size)
        assertTrue(host.isRunning)
    }

    @Test
    fun unknownAndMalformedEffectsAreIgnored() {
        transport.enqueue(ok("""{"type":"capture.request"}""", """{"type":"capture.request"}""", """{"type":"timer.cancel"}"""))
        transport.enqueue(response(EngineStatus.OK, "not json"))
        post("a")
        post("b")
        post("c")
        looper.idle()

        assertEquals(3, transport.submitted.size)
        assertTrue(host.isRunning)
    }

    @Test
    fun closeRunsQueuedWorkThenReleasesEverything() {
        frames.put(byteArrayOf(1))
        transport.enqueue(ok("""{"type":"timer.schedule","timerId":"t","atMonoUs":${(SystemClock.uptimeMillis() + 10) * 1000}}"""))
        post("a")
        host.close()
        post("afterClose")
        looper.idleFor(Duration.ofSeconds(1))

        assertEquals(listOf("""{"type":"a",$factAtJson,"input":{}}""", dispose), transport.submitted)
        assertEquals("engine.dispose comes before the handle is destroyed", 2, transport.submittedAtClose)
        assertTrue(transport.closed)
        assertTrue(http.closed)
        assertEquals(0, frames.size)
        assertEquals(1, shutDowns)
        assertFalse(host.isRunning)
    }

    @Test
    fun disposeStartsNoNewWorkButReleasesFrames() {
        val released = frames.put(byteArrayOf(1))
        val kept = frames.put(byteArrayOf(2))
        post("a", listOf(released, kept))
        looper.idle()
        transport.enqueue(
            ok(
                """{"type":"http.send","requestId":"http-1","lane":"events","path":"/v1/events/batch",""" +
                    """"timeoutMs":1000,"jsonBody":"{}"}""",
                """{"type":"timer.schedule","timerId":"t","atMonoUs":0}""",
                """{"type":"frame.release","handle":"$released"}""",
            ),
        )
        // The handle is destroyed before the frame table is cleared, so this
        // sees what engine.dispose's own effects did.
        var atHandleClose: Pair<Boolean, Boolean>? = null
        transport.onClose = { atHandleClose = (frames[released] == null) to (frames[kept] == null) }

        host.close()
        looper.idleFor(Duration.ofSeconds(1))

        assertEquals(dispose, transport.submitted.last())
        assertEquals("no timer.fired after close", 2, transport.submitted.size)
        assertTrue("no http.send after close", http.requests.isEmpty())
        assertEquals("frame.release is honoured", true to false, atHandleClose)
        assertEquals(0, frames.size)
    }

    @Test
    fun anEngineWithoutDisposeIsStillDestroyed() {
        transport.enqueue(
            response(
                EngineStatus.UNSUPPORTED_MESSAGE,
                """{"error":{"status":"unsupported_message","message":"unknown message type"}}""",
            ),
        )
        host.close()
        looper.idle()

        assertEquals(listOf(dispose), transport.submitted)
        assertTrue(transport.closed)
        assertTrue(http.closed)
        assertEquals(1, shutDowns)
    }
}
