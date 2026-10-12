package com.tugboat.android.sdk

import com.tugboat.android.host.FakeHttpSender
import com.tugboat.android.host.HttpBody
import com.tugboat.android.host.HttpRequest
import com.tugboat.android.host.TransportOutcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** `stop()`: `session.end`, then dispose only once `session_end` settled (or the drain bound passed). */
@RunWith(RobolectricTestRunner::class)
class StopTest {
    private val http = FakeHttpSender()
    private val watcher = SessionEndWatcher(http)
    private val steps = CopyOnWriteArrayList<String>()

    private fun lifecycle(eventType: String) =
        HttpRequest("http-1", "lifecycle", "/v1/sessions", 15_000, HttpBody.Json("""{"eventType":"$eventType"}"""))

    @Test
    fun onlyAFinalAnswerToSessionEndSettles() {
        var settled = 0
        watcher.whenSettled { settled++ }

        watcher.send(lifecycle("session_start")) {}
        http.complete(0, TransportOutcome.Http(202, "{}"))
        watcher.send(HttpRequest("http-2", "events", "/v1/events/batch", 1, HttpBody.Json("""{"eventType":"session_end"}"""))) {}
        http.complete(1, TransportOutcome.Http(202, "{}"))
        watcher.send(lifecycle("session_end")) {}
        http.complete(2, TransportOutcome.Http(503, ""))
        http.complete(2, TransportOutcome.Timeout)
        assertEquals("retried outcomes keep waiting", 0, settled)

        val answered = ArrayList<TransportOutcome>()
        watcher.send(lifecycle("session_end")) { answered += it }
        http.complete(3, TransportOutcome.Http(202, "{}"))
        assertEquals(1, settled)
        assertEquals("the engine still gets its answer", 1, answered.size)
    }

    @Test
    fun aDroppedSessionEndIsFinalToo() {
        assertTrue(SessionEndWatcher.isFinal(TransportOutcome.Http(400, "")))
        assertFalse(SessionEndWatcher.isFinal(TransportOutcome.Http(429, "")))
        assertFalse(SessionEndWatcher.isFinal(TransportOutcome.Error))
    }

    @Test
    fun theSequenceEndsTheSessionThenFinishesOnceAfterItSettles() {
        val finished = CountDownLatch(1)
        StopSequence(maxDrainMs = 60_000).run(
            watcher = watcher,
            endSession = { steps += "session.end" },
            finish = {
                steps += "dispose"
                finished.countDown()
            },
        )
        assertEquals(listOf("session.end"), steps)

        watcher.send(lifecycle("session_end")) {}
        http.complete(0, TransportOutcome.Http(202, "{}"))

        assertTrue(finished.await(5, TimeUnit.SECONDS))
        Thread.sleep(50)
        assertEquals(listOf("session.end", "dispose"), steps)
    }

    @Test
    fun theDrainBoundFinishesWhenSessionEndNeverSettles() {
        val finished = CountDownLatch(1)
        StopSequence(maxDrainMs = 50).run(watcher, endSession = { steps += "session.end" }, finish = {
            steps += "dispose"
            finished.countDown()
        })

        assertTrue(finished.await(5, TimeUnit.SECONDS))
        assertEquals(listOf("session.end", "dispose"), steps)
    }
}
