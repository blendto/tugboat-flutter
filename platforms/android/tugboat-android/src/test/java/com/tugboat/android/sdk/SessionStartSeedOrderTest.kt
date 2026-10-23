package com.tugboat.android.sdk

import android.app.Activity
import android.app.Application
import android.os.Looper
import com.tugboat.android.AppInfo
import com.tugboat.android.CollectorConfig
import com.tugboat.android.TugboatConfig
import com.tugboat.android.host.FakeEngineTransport
import com.tugboat.android.views.navigation.NavigationObservation
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Seeds reach the engine inside `start()`, before `lifecycle.start()` replays
 * `resumed` and the engine requests a lifecycle capture (review 3 m1).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class SessionStartSeedOrderTest {
    private val application = RuntimeEnvironment.getApplication() as Application
    private val config = TugboatConfig(
        collector = CollectorConfig("http://10.0.2.2:3000", "pmk_blend-app-dev-secret"),
        app = AppInfo("Sample", "1.0.0", "1", "com.example.sample", "install-1"),
    )

    @Before
    fun reset() {
        NavigationObservation.resetForTests()
    }

    @Test
    fun seedsArePostedInsideStartBeforeAnyFrame() {
        val first = start(FakeEngineTransport())
        Robolectric.buildActivity(Activity::class.java).setup()
        shadowOf(Looper.getMainLooper()).idle()
        first.stop()

        // No main-looper idling from here: a seed left for the next frame
        // would arrive after `lifecycle.start()` replays the app state.
        val transport = FakeEngineTransport()
        val second = start(transport)
        try {
            awaitEngineThread { "session.start" in types(transport) }
            val types = types(transport)
            assertTrue("seed posted inside start(): $types", types.indexOf("navigation") > types.indexOf("session.start"))
        } finally {
            second.stop()
        }
    }

    private fun start(transport: FakeEngineTransport): TugboatRuntime {
        val runtime = TugboatRuntime.start(
            application,
            config,
            sessionEpoch = 0,
            openTransport = { transport },
            stopSequence = StopSequence(maxDrainMs = 10),
        )
        assertTrue(runtime != null)
        return runtime ?: throw AssertionError("runtime did not start")
    }

    private fun types(transport: FakeEngineTransport): List<String> =
        transport.submitted.map { JSONObject(it) }.flatMap(::messageTypes)

    /** Waits for the engine thread only; the main looper is not advanced. */
    private fun awaitEngineThread(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (!condition() && System.currentTimeMillis() < deadline) Thread.sleep(10)
        Thread.sleep(100) // let anything posted in the same start() reach the transport
        assertTrue("timed out", condition())
    }

    /** A submit is one message (`type`) or a batch (`messages[].type`). */
    private fun messageTypes(json: JSONObject): List<String> {
        val batch = json.optJSONArray("messages") ?: return listOf(json.optString("type"))
        return (0 until batch.length()).map { batch.getJSONObject(it).optString("type") }
    }
}
