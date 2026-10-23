package com.tugboat.android.sdk

import android.app.Application
import android.os.Looper
import com.tugboat.android.AppInfo
import com.tugboat.android.CollectorConfig
import com.tugboat.android.Tugboat
import com.tugboat.android.TugboatConfig
import com.tugboat.android.host.FakeEngineTransport
import com.tugboat.android.views.navigation.NavigationObservation
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf

/** The composition root against a fake engine: message order from start to dispose. */
@RunWith(RobolectricTestRunner::class)
class TugboatRuntimeTest {
    private val application = RuntimeEnvironment.getApplication() as Application
    @Before
    fun resetNavigation() = NavigationObservation.resetForTests()

    private val config = TugboatConfig(
        collector = CollectorConfig("http://10.0.2.2:3000", "pmk_blend-app-dev-secret"),
        app = AppInfo("Sample", "1.0.0", "1", "com.example.sample", "install-1"),
        captureFocusChanges = true,
        captureSystemInput = true,
    )

    @Test
    fun startConfiguresThenStartsAndStopEndsThenDisposes() {
        val transport = FakeEngineTransport()
        val runtime = TugboatRuntime.start(
            application,
            config,
            sessionEpoch = 0,
            openTransport = { transport },
            stopSequence = StopSequence(maxDrainMs = 10),
        )
        assertNotNull(runtime)
        runtime!!.setUserId("user-1")
        runtime.setTraits(SessionMessages.traits(mapOf("plan" to "pro")))
        runtime.stop()
        runtime.stop()

        awaitUntil { transport.closed }
        assertEquals(
            listOf(
                "engine.configure", "session.start", "identity.set", "traits.set", "session.end", "engine.dispose",
            ),
            transport.submitted.map { JSONObject(it).getString("type") },
        )
        val configure = JSONObject(transport.submitted.first()).getJSONObject("input")
        assertEquals("1.0.0", configure.getJSONObject("host").getJSONObject("app").getString("version"))
    }

    @Test
    fun missingSessionStartFieldsRefuseToStartWithoutOpeningAnEngine() {
        var opened = false
        val runtime = TugboatRuntime.start(
            application,
            config.copy(app = config.app.copy(buildNumber = "")),
            sessionEpoch = 0,
            openTransport = {
                opened = true
                FakeEngineTransport()
            },
        )

        assertNull(runtime)
        assertTrue(!opened)
    }

    @Test
    fun anUnavailableEngineRefusesToStart() {
        assertNull(TugboatRuntime.start(application, config, sessionEpoch = 0, openTransport = { null }))
    }

    @Test
    fun theFacadeNeverThrowsIntoTheApp() {
        // No libtugboat_engine.so on the JVM: start logs and stays stopped.
        Tugboat.start(application, config)
        Tugboat.start(application, config.copy(app = config.app.copy(version = "")))
        Tugboat.setUserId(null)
        Tugboat.setTraits(mapOf("bad" to Double.NaN, "nested" to mapOf("a" to listOf(1, 2))))
        Tugboat.stop()
        Tugboat.stop()
        Thread { Tugboat.setUserId("from another thread") }.apply { start() }.join()
        shadowOf(Looper.getMainLooper()).idle()
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
