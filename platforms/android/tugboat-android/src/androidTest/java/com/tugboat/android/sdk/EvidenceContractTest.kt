package com.tugboat.android.sdk

import android.app.Application
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.tugboat.android.AppInfo
import com.tugboat.android.CollectorConfig
import com.tugboat.android.EventHook
import com.tugboat.android.NetworkFailure
import com.tugboat.android.ParameterPolicy
import com.tugboat.android.TugboatConfig
import com.tugboat.android.engine.JniEngineTransport
import com.tugboat.android.evidence.EngineEvidenceEncoder
import com.tugboat.android.evidence.EvidenceRecorder
import com.tugboat.android.host.EngineHost
import com.tugboat.android.host.FrameHandleTable
import com.tugboat.android.host.HttpBody
import com.tugboat.android.host.HttpRequest
import com.tugboat.android.host.HttpSender
import com.tugboat.android.host.SystemHostClock
import com.tugboat.android.host.TransportOutcome
import com.tugboat.android.views.input.GestureConfig
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The real engine takes the SDK's `evidence.externalEvent` and
 * `evidence.networkCall` messages, applies the policy and limits, and
 * delivers `external_event` and `network_call` records to the collector on
 * `/v1/events/batch`. Only the transport is fake. The collector record
 * carries the event data as `payload`.
 */
@RunWith(AndroidJUnit4::class)
class EvidenceContractTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
    private val app = AppInfo("Contract", "3.1.4", "314", "com.tugboat.contract", "install-contract")
    private val config = TugboatConfig(CollectorConfig("http://127.0.0.1:9", "key"), app)
    private val http = RecordingSender()
    private lateinit var host: EngineHost

    @After
    fun tearDown() {
        if (::host.isInitialized) host.close()
    }

    @Test
    fun codedEventsAndNetworkCallsReachTheCollectorBounded() {
        val device = DeviceSnapshot.read(context)
        val metadata = HostMetadata(app, device)
        val transport = checkNotNull(JniEngineTransport.open()) { "libtugboat_engine.so must load" }
        host = EngineHost.start(transport, FrameHandleTable(), http = http, captures = {})
        host.postUntimed(SessionMessages.ENGINE_CONFIGURE, EngineConfiguration.build(config, metadata, GestureConfig.from(context)).toString())
        host.post(
            SessionMessages.SESSION_START,
            SessionMessages.sessionStart(device, metadata, 0, activationRequestId = null, explorationRunId = null),
            SystemHostClock.now(),
        )
        awaitRequest { it.lane == "lifecycle" }

        val recorder = EvidenceRecorder(SystemHostClock, EngineEvidenceEncoder, hostRunning = { host.isRunning }, post = host::post)
        val hook = EventHook(" analytics ", ParameterPolicy.allowList(setOf("method"))) { recorder }
        hook.record("USER_LOGIN", linkedMapOf("method" to "email", "password" to "hunter2", "ratio" to 0.5))
        recorder.beginNetworkCall("get", "/orders/123")
            .complete(statusCode = 422, attemptCount = 2, errorResponseBody = mapOf("code" to "invalid_project"))
        val failed = recorder.beginNetworkCall("POST", "/projects")
        failed.fail(NetworkFailure.NETWORK_ERROR)
        failed.complete(statusCode = 200)
        // The engine records nothing for a route that is a URL.
        recorder.beginNetworkCall("GET", "https://example.com/x?token=1").complete(statusCode = 200)
        host.post(SessionMessages.SESSION_END, SessionMessages.sessionEnd(), SystemHostClock.now())
        awaitRequest { it.lane == "lifecycle" && "session_end" in it.json() }

        val records = http.requests.filter { it.lane == "events" }
            .flatMap { request ->
                val events = JSONObject(request.json()).getJSONArray("events")
                (0 until events.length()).map { events.getJSONObject(it) }
            }
        val external = records.single { it.getString("eventType") == "external_event" }
        assertEquals("evidence", external.getString("stream"))
        val event = external.getJSONObject("payload")
        assertEquals("analytics", event.getString("source"))
        assertEquals("USER_LOGIN", event.getString("name"))
        assertEquals("[\"method\",\"password\",\"ratio\"]", event.getJSONArray("parameterKeys").toString())
        assertEquals("{\"method\":\"email\"}", event.getJSONObject("parameters").toString())
        assertFalse("hunter2" in external.toString())

        val calls = records.filter { it.getString("eventType") == "network_call" }.map { it.getJSONObject("payload") }
        assertEquals(listOf("GET /orders/123", "POST /projects"), calls.map { it.getString("method") + " " + it.getString("route") })
        val call = calls[0]
        assertEquals(422, call.getInt("statusCode"))
        assertEquals("response", call.getString("outcome"))
        assertEquals(2, call.getInt("attemptCount"))
        assertEquals("{\"code\":\"invalid_project\"}", call.getJSONObject("errorResponseBody").toString())
        assertEquals("network_error", calls[1].getString("outcome"))
        assertFalse(calls[1].has("statusCode"))
    }

    private fun awaitRequest(match: (HttpRequest) -> Boolean): HttpRequest {
        val deadline = System.currentTimeMillis() + 20_000
        while (System.currentTimeMillis() < deadline) {
            http.requests.firstOrNull(match)?.let { return it }
            Thread.sleep(20)
        }
        throw AssertionError("no matching http.send; saw ${http.requests.map { it.lane + " " + it.path }}")
    }

    private fun HttpRequest.json(): String = (body as? HttpBody.Json)?.text.orEmpty()

    /** Records each request and accepts it, with a collector session id for lifecycle posts. */
    private class RecordingSender : HttpSender {
        val requests = CopyOnWriteArrayList<HttpRequest>()

        override fun send(request: HttpRequest, onResult: (TransportOutcome) -> Unit) {
            requests += request
            val body = if (request.lane == "lifecycle") """{"accepted":true,"sessionId":"collector-1"}""" else """{"accepted":true}"""
            onResult(TransportOutcome.Http(202, body))
        }

    }
}
