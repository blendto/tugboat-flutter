package com.tugboat.android.sdk

import android.app.Application
import android.os.Looper
import com.tugboat.android.AppInfo
import com.tugboat.android.CollectorConfig
import com.tugboat.android.EventHook
import com.tugboat.android.NetworkFailure
import com.tugboat.android.ParameterPolicy
import com.tugboat.android.TugboatConfig
import com.tugboat.android.host.FakeEngineTransport
import com.tugboat.android.views.navigation.NavigationObservation
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf

/** Coded events and network calls reach the engine through the running SDK's host, and stop with it. */
@RunWith(RobolectricTestRunner::class)
class EvidenceRuntimeTest {
    private val application = RuntimeEnvironment.getApplication() as Application
    @Before
    fun resetNavigation() = NavigationObservation.resetForTests()

    private val config = TugboatConfig(
        collector = CollectorConfig("http://10.0.2.2:3000", "key"),
        app = AppInfo("Sample", "1.0.0", "1", "com.example.sample", "install-1"),
    )

    @Test
    fun evidenceFromAnyThreadIsSubmittedUntilStop() {
        val transport = FakeEngineTransport()
        val runtime = TugboatRuntime.start(
            application,
            config,
            sessionEpoch = 0,
            openTransport = { transport },
            stopSequence = StopSequence(maxDrainMs = 10),
        )!!
        val hook = EventHook("analytics", ParameterPolicy.allowList(setOf("method"))) { runtime.evidence }

        Thread {
            hook.record("USER_LOGIN", mapOf("method" to "email", "password" to "hunter2"))
            runtime.evidence.beginNetworkCall("GET", "/orders/123").complete(statusCode = 404, errorResponseBody = mapOf("code" to "missing"))
        }.apply { start() }.join()
        val late = runtime.evidence.beginNetworkCall("POST", "/late")
        runtime.stop()
        late.fail(NetworkFailure.NETWORK_ERROR)
        hook.record("AFTER_STOP")

        awaitUntil { transport.closed }
        val messages = transport.submitted.map(::JSONObject)
        assertEquals(
            listOf("engine.configure", "session.start", "evidence.externalEvent", "evidence.networkCall", "session.end", "engine.dispose"),
            messages.map { it.getString("type") },
        )
        val event = messages[2]
        val input = event.getJSONObject("input")
        assertEquals("USER_LOGIN", input.getString("name"))
        assertEquals("allow_list", input.getJSONObject("policy").getString("mode"))
        assertTrue(input.toString(), "hunter2" !in input.toString())
        assertEquals(event.getJSONObject("at").getLong("monoUs"), input.getLong("atMonoUs"))

        val call = messages[3]
        val callInput = call.getJSONObject("input")
        assertEquals(call.getJSONObject("at").getLong("monoUs"), callInput.getLong("endMonoUs"))
        assertTrue(callInput.getLong("startMonoUs") <= callInput.getLong("endMonoUs"))
        assertEquals(404, callInput.getInt("statusCode"))
        assertEquals("response", callInput.getString("outcome"))
        assertEquals(
            "{\"value\":{\"map\":[[\"code\",\"missing\"]]}}",
            callInput.getJSONObject("errorResponseBody").toString(),
        )
    }

    private fun awaitUntil(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (!condition() && System.currentTimeMillis() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(10)
        }
        assertTrue("timed out", condition())
    }
}
