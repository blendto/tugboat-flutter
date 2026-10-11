package com.tugboat.android.host

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.tugboat.android.engine.EngineStatus
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

    private val at = """"at":{"monoUs":1000000,"wallUs":1791712345678901}"""

    @Test
    fun postsAreSubmittedInOrderOnTheEngineThread() {
        host.post("""{"type":"a"}""")
        host.postUntimed("""{"type":"b"}""")
        host.post("""{"type":"c"}""")
        assertEquals("nothing runs on the caller's thread", 0, transport.submitted.size)

        looper.idle()
        assertEquals(
            listOf("""{$at,"type":"a"}""", """{"type":"b"}""", """{$at,"type":"c"}"""),
            transport.submitted,
        )
        assertTrue(transport.submitThreads.all { it == Looper.getMainLooper().thread })
    }

    @Test
    fun postsFromManyThreadsAreSerialized() {
        val threads = (0 until 4).map { t ->
            Thread { repeat(25) { i -> host.post("""{"type":"t$t","input":{"i":$i}}""") } }
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
    fun atIsTakenWhenPostedAndCallerAtWins() {
        host.post("""{"type":"a"}""")
        clock.monoUs = 9_999
        host.post("""{"type":"b","at":{"monoUs":5}}""")
        looper.idle()

        assertEquals("""{$at,"type":"a"}""", transport.submitted[0])
        assertEquals("""{"type":"b","at":{"monoUs":5}}""", transport.submitted[1])
    }

    @Test
    fun batchStampsEachMessage() {
        host.postBatch(listOf("""{"type":"a"}""", """{"type":"b","at":{"monoUs":1}}"""))
        host.postBatch(emptyList())
        looper.idle()

        assertEquals(
            listOf("""{"type":"batch","messages":[{$at,"type":"a"},{"type":"b","at":{"monoUs":1}}]}"""),
            transport.submitted,
        )
    }

    @Test
    fun effectsRunInResponseOrder() {
        val handle = frames.put(byteArrayOf(1))
        val upload = """{"type":"http.send","requestId":"r","lane":"frames","path":"/v1/frames","timeoutMs":1,""" +
            """"multipart":{"fields":{},"frames":[{"handle":"$handle","filename":"1.jpg"}]}}"""
        val release = """{"type":"frame.release","handle":"$handle"}"""
        transport.enqueue(ok(upload, release))
        transport.enqueue(ok(release, upload))

        host.post("""{"type":"first"}""")
        host.post("""{"type":"second"}""")
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
        host.post("""{"type":"session.start"}""")
        looper.idle()

        looper.idleFor(Duration.ofMillis(299))
        assertEquals(1, transport.submitted.size)
        clock.monoUs = (now + 300) * 1000
        looper.idleFor(Duration.ofMillis(1))
        assertEquals(
            """{"at":{"monoUs":${(now + 300) * 1000},"wallUs":1791712345678901},""" +
                """"type":"timer.fired","input":{"timerId":"flush"}}""",
            transport.submitted.last(),
        )
        looper.idleFor(Duration.ofSeconds(5))
        assertEquals(2, transport.submitted.size)
    }

    @Test
    fun transportResultsComeBackThroughTheEngineThread() {
        transport.enqueue(
            ok("""{"type":"http.send","requestId":42,"lane":"events","path":"/v1/events/batch","timeoutMs":15000,"json":{"a":1.0}}"""),
        )
        host.post("""{"type":"flush"}""")
        looper.idle()
        assertEquals(HttpBody.Json("{\"a\":1.0}"), http.requests.single().body)

        val io = Thread { http.complete(0, TransportOutcome.Http(202, "{\"sessionId\":\"s\"}")) }
        io.start()
        io.join()
        assertEquals("not submitted from the IO thread", 1, transport.submitted.size)
        looper.idle()

        val result = JSONObject(transport.submitted.last())
        assertEquals("transport.result", result.getString("type"))
        assertEquals(1_000_000L, result.getJSONObject("at").getLong("monoUs"))
        assertEquals(42, result.getJSONObject("input").getInt("requestId"))
        assertEquals(202, result.getJSONObject("input").getInt("status"))
    }

    @Test
    fun rejectedMessagesAreDroppedAndTheHostKeepsGoing() {
        transport.enqueue(
            response(EngineStatus.INVALID_MESSAGE, """{"error":{"status":"invalid_message"},"effects":[{"type":"frame.release","handle":"h"}]}"""),
        )
        val handle = frames.put(byteArrayOf(1))
        transport.enqueue(ok("""{"type":"frame.release","handle":"$handle"}"""))

        host.post("""{"type":"bad"}""")
        host.post("""{"type":"good"}""")
        looper.idle()

        assertEquals(2, transport.submitted.size)
        assertEquals(0, frames.size)
        assertTrue(host.isRunning)
    }

    @Test
    fun consecutiveInternalErrorsDisableTheHost() {
        frames.put(byteArrayOf(1))
        transport.enqueue(ok("""{"type":"timer.schedule","timerId":"t","atMonoUs":${(SystemClock.uptimeMillis() + 10) * 1000}}"""))
        repeat(EngineHost.DEFAULT_MAX_CONSECUTIVE_INTERNAL_ERRORS) { transport.enqueue(failure(EngineStatus.INTERNAL_ERROR)) }

        repeat(1 + EngineHost.DEFAULT_MAX_CONSECUTIVE_INTERNAL_ERRORS) { host.post("""{"type":"m$it"}""") }
        host.post("""{"type":"queuedBeforeDisable"}""")
        looper.idle()
        host.post("""{"type":"afterDisable"}""")
        looper.idleFor(Duration.ofSeconds(1))

        assertEquals(1 + EngineHost.DEFAULT_MAX_CONSECUTIVE_INTERNAL_ERRORS, transport.submitted.size)
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

        repeat(5) { host.post("""{"type":"m$it"}""") }
        looper.idle()

        assertTrue(host.isRunning)
        assertFalse(transport.closed)
    }

    @Test
    fun transportExceptionsNeverEscape() {
        transport.throwOnSubmit = IllegalStateException("boom")
        host.post("""{"type":"a"}""")
        looper.idle()
        transport.throwOnSubmit = null
        host.post("""{"type":"b"}""")
        looper.idle()

        assertEquals(2, transport.submitted.size)
        assertTrue(host.isRunning)
    }

    @Test
    fun unknownAndMalformedEffectsAreIgnored() {
        transport.enqueue(ok("""{"type":"capture.request"}""", """{"type":"capture.request"}""", """{"type":"timer.cancel"}"""))
        transport.enqueue(response(EngineStatus.OK, "not json"))
        host.post("""{"type":"a"}""")
        host.post("""{"type":"b"}""")
        host.post("""{"type":"c"}""")
        looper.idle()

        assertEquals(3, transport.submitted.size)
        assertTrue(host.isRunning)
    }

    @Test
    fun closeRunsQueuedWorkThenReleasesEverything() {
        frames.put(byteArrayOf(1))
        transport.enqueue(ok("""{"type":"timer.schedule","timerId":"t","atMonoUs":${(SystemClock.uptimeMillis() + 10) * 1000}}"""))
        host.post("""{"type":"a"}""")
        host.close()
        host.post("""{"type":"afterClose"}""")
        looper.idleFor(Duration.ofSeconds(1))

        assertEquals(listOf("""{$at,"type":"a"}"""), transport.submitted)
        assertTrue(transport.closed)
        assertTrue(http.closed)
        assertEquals(0, frames.size)
        assertEquals(1, shutDowns)
        assertFalse(host.isRunning)
    }
}
