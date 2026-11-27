package com.tugboat.android.evidence

import com.tugboat.android.EventHook
import com.tugboat.android.NetworkCall
import com.tugboat.android.NetworkFailure
import com.tugboat.android.ParameterPolicy
import com.tugboat.android.Tugboat
import com.tugboat.android.host.HostClock
import com.tugboat.android.host.HostTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicLong

/** The host side of coded events and network calls: tokens, no-op paths, and the transform policy. */
class EvidenceRecorderTest {
    private val clock = StepClock()
    private val encoder = RecordingEncoder()
    private val posts = CopyOnWriteArrayList<Post>()
    private var hostRunning = true
    private val recorder = EvidenceRecorder(clock, encoder, hostRunning = { hostRunning }) { type, input, at ->
        posts += Post(type, input, at)
    }

    @Test
    fun aNetworkCallIsPostedOnceWithItsBeginAndFinishTimes() {
        val call = recorder.beginNetworkCall("GET", "/orders/123")
        call.complete(statusCode = 404, attemptCount = 2, errorResponseBody = mapOf("code" to "missing"))

        val input = encoder.calls.single()
        assertEquals("GET", input.method)
        assertEquals("/orders/123", input.route)
        assertEquals(1_000L, input.startMonoUs)
        assertEquals(2_000L, input.endMonoUs)
        assertEquals(404, input.statusCode)
        assertEquals(NetworkOutcome.Response, input.outcome)
        assertEquals(2, input.attemptCount)
        assertEquals(mapOf("code" to "missing"), input.errorResponseBody)
        val post = posts.single()
        assertEquals(EvidenceMessages.NETWORK_CALL, post.type)
        assertEquals(2_000L, post.at.monoUs)
    }

    @Test
    fun aSecondFinishOfEitherKindIsIgnored() {
        val call = recorder.beginNetworkCall("POST", "/projects")
        call.fail(NetworkFailure.NETWORK_ERROR)
        call.complete(statusCode = 200)
        call.fail(NetworkFailure.CANCELLED)

        assertEquals(listOf(NetworkOutcome.NetworkError), encoder.calls.map { it.outcome })
        assertEquals(1, posts.size)
    }

    @Test
    fun cancelledMapsToItsOutcome() {
        recorder.beginNetworkCall("GET", "/feed").fail(NetworkFailure.CANCELLED, statusCode = 499)

        assertEquals(NetworkOutcome.Cancelled, encoder.calls.single().outcome)
        assertEquals(499, encoder.calls.single().statusCode)
    }

    @Test
    fun concurrentFinishesPostExactlyOnce() {
        repeat(50) {
            encoder.calls.clear()
            val call = recorder.beginNetworkCall("GET", "/race")
            val ready = CountDownLatch(8)
            val go = CountDownLatch(1)
            val threads = (0 until 8).map { i ->
                Thread {
                    ready.countDown()
                    go.await()
                    if (i % 2 == 0) call.complete(statusCode = 200) else call.fail(NetworkFailure.NETWORK_ERROR)
                }.apply { start() }
            }
            ready.await()
            go.countDown()
            threads.forEach { it.join() }
            assertEquals(1, encoder.calls.size)
        }
    }

    @Test
    fun anEmptyBlankOrNullRouteGivesANoOpCall() {
        assertSame(NetworkCall.NOOP, recorder.beginNetworkCall("GET", ""))
        assertSame(NetworkCall.NOOP, recorder.beginNetworkCall("GET", "  \t"))
        assertSame(NetworkCall.NOOP, recorder.beginNetworkCall("GET", null))
        NetworkCall.NOOP.complete(statusCode = 200)
        NetworkCall.NOOP.fail(NetworkFailure.CANCELLED)

        assertTrue(posts.isEmpty())
    }

    @Test
    fun nothingIsRecordedOnceClosedOrWhileTheHostIsDown() {
        val begunBefore = recorder.beginNetworkCall("GET", "/before")
        hostRunning = false
        assertSame(NetworkCall.NOOP, recorder.beginNetworkCall("GET", "/down"))
        recorder.recordExternalEvent("DOWN", null, ParameterPolicy.allowAll, null)
        hostRunning = true
        recorder.close()
        assertSame(NetworkCall.NOOP, recorder.beginNetworkCall("GET", "/closed"))
        recorder.recordExternalEvent("CLOSED", null, ParameterPolicy.allowAll, null)
        begunBefore.complete(statusCode = 200)

        assertTrue(posts.isEmpty())
    }

    @Test
    fun anExternalEventPassesItsValuesThrough() {
        val parameters = mapOf("method" to "email", "count" to 3)
        recorder.recordExternalEvent("USER_LOGIN", "analytics", ParameterPolicy.allowList(setOf("method")), parameters)

        val event = encoder.events.single()
        assertEquals("USER_LOGIN", event.name)
        assertEquals("analytics", event.source)
        assertEquals(ParameterPolicy.Mode.AllowList, event.policy.mode)
        assertSame(parameters, event.parameters)
        assertEquals(1_000L, event.atMonoUs)
        assertEquals(EvidenceMessages.EXTERNAL_EVENT, posts.single().type)
        assertEquals(1_000L, posts.single().at.monoUs)
    }

    @Test
    fun anEncoderFailureNeverReachesTheApp() {
        val failing = EvidenceRecorder(clock, ThrowingEncoder, hostRunning = { true }) { _, _, _ -> error("unreachable") }
        val hook = EventHook("analytics", ParameterPolicy.allowAll) { failing }

        hook.record("E", mapOf("k" to "v"))
        failing.beginNetworkCall("GET", "/x").complete(statusCode = 500, errorResponseBody = "boom")
    }

    @Test
    fun aHookRecordsIntoWhicheverRecorderIsCurrent() {
        var current: EvidenceRecorder? = null
        val hook = EventHook("analytics", ParameterPolicy.namesOnly) { current }
        hook.record("BEFORE")
        current = recorder
        hook.record("DURING", mapOf("k" to "v"))
        current = null
        hook.record("AFTER")

        assertEquals(listOf("DURING"), encoder.events.map { it.name })
    }

    @Test
    fun theFacadeGivesNoOpsWhenNotStarted() {
        assertSame(NetworkCall.NOOP, Tugboat.beginNetworkCall("GET", "/orders/1"))
        Tugboat.eventHook().record("NOT_STARTED", mapOf("k" to "v"))
        Tugboat.eventHook(source = "analytics").record("NOT_STARTED")
    }

    private data class Post(val type: String, val input: String, val at: HostTime)

    /** Each reading is 1000 µs later than the last. */
    private class StepClock : HostClock {
        private val mono = AtomicLong(0)
        override fun now(): HostTime {
            val us = mono.addAndGet(1_000)
            return HostTime(us, 1_700_000_000_000_000 + us)
        }
    }

    private class RecordingEncoder : EvidenceEncoder {
        val events = CopyOnWriteArrayList<ExternalEventInput>()
        val calls = CopyOnWriteArrayList<NetworkCallInput>()

        override fun externalEvent(event: ExternalEventInput): String {
            events += event
            return "{}"
        }

        override fun networkCall(call: NetworkCallInput): String {
            calls += call
            return "{}"
        }
    }

    private object ThrowingEncoder : EvidenceEncoder {
        override fun externalEvent(event: ExternalEventInput): String = throw StackOverflowError()
        override fun networkCall(call: NetworkCallInput): String = throw IllegalStateException()
    }
}
