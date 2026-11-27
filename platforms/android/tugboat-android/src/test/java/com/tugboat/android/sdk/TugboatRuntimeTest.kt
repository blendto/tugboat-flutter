package com.tugboat.android.sdk

import android.app.Application
import android.os.Looper
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ProcessLifecycleOwner
import com.tugboat.android.AppInfo
import com.tugboat.android.CollectorConfig
import com.tugboat.android.Tugboat
import com.tugboat.android.TugboatConfig
import com.tugboat.android.engine.EngineStatus
import com.tugboat.android.host.FakeEngineTransport
import com.tugboat.android.host.failure
import com.tugboat.android.outbox.Outboxes
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
import org.robolectric.annotation.Config
import org.robolectric.Shadows.shadowOf
import org.robolectric.shadows.ShadowLog

/** The composition root against a fake engine: message order from start to dispose. */
@RunWith(RobolectricTestRunner::class)
@Config(application = CallbackCountingApplication::class)
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

    /** BLE-664: after the host disables itself nothing feeds or replays for it; `stop` stays safe. */
    @Test
    fun aHostThatDisablesItselfStopsTheDrainerAndTheObservers() {
        val outbox = Outboxes.at(application)
        val transport = FakeEngineTransport(*Array(3) { failure(EngineStatus.INTERNAL_ERROR) })
        // Navigation observation is process-scoped and stays installed; count only what the session adds.
        NavigationObservation.ensureInstalled(application)
        val activityBefore = activityCallbacks()
        val componentBefore = componentCallbacks()
        val processBefore = processObservers()
        val runtime = TugboatRuntime.start(
            application,
            config.copy(durableOutbox = true),
            sessionEpoch = 0,
            openTransport = { transport },
            stopSequence = StopSequence(maxDrainMs = 10),
        )!!
        assertTrue("the drainer listens while the session runs", outbox.hasSessionListeners)
        assertTrue("the Views adapter and the foreground window observe", activityCallbacks() > activityBefore)
        assertTrue("the locale bridge observes", componentCallbacks() > componentBefore)
        assertTrue("the lifecycle bridge observes", processObservers() > processBefore)

        // configure and session.start are two internal errors; this is the third.
        runtime.setUserId("user-1")
        awaitUntil { !runtime.isHostRunning }
        awaitUntil { !outbox.hasSessionListeners }

        // Each observer, not only the drainer: a live adapter keeps encoding a fact for every frame.
        assertEquals("adapter and foreground window detached", activityBefore, activityCallbacks())
        assertEquals("locale bridge detached", componentBefore, componentCallbacks())
        assertEquals("lifecycle bridge detached", processBefore, processObservers())

        runtime.stop()
        runtime.stop()
        awaitUntil { transport.closed }
        Outboxes.resetForTests()
    }

    /** BLE-664: `Tugboat.start` refuses before it stores a config, so the session start does not check it again. */
    @Test
    fun aValidatedConfigIsNotCheckedAgainAtSessionStart() {
        val unchecked = config.copy(app = config.app.copy(buildNumber = ""))
        val transport = FakeEngineTransport()

        val runtime = TugboatRuntime.start(
            application,
            unchecked,
            sessionEpoch = 0,
            openTransport = { transport },
            stopSequence = StopSequence(maxDrainMs = 10),
            validated = true,
        )

        assertNotNull("the fields were checked by the caller", runtime)
        runtime!!.stop()
        awaitUntil { transport.closed }
    }

    /** PR #100 review: the Apple host's rule, an absolute `http`/`https` URL with a host. */
    @Test
    fun aMalformedCollectorUrlRefusesToStartWithoutOpeningAnEngine() {
        for (url in listOf(
            "collector.example.com",
            "/v1",
            "ftp://collector.example.com",
            "file:///tmp/collector",
            "mailto:ops@example.com",
            "http://",
            "http:///v1",
            "https://exa mple.com",
            " ",
        )) {
            var opened = false
            ShadowLog.clear()
            val runtime = TugboatRuntime.start(
                application,
                config.copy(collector = config.collector.copy(baseUrl = url)),
                sessionEpoch = 0,
                openTransport = {
                    opened = true
                    FakeEngineTransport()
                },
            )

            assertNull(url, runtime)
            assertTrue(url, !opened)
            assertEquals(url, listOf("collector.baseUrl"), TugboatRuntime.refusal(application, config.copy(collector = config.collector.copy(baseUrl = url))))
            assertTrue(url, ShadowLog.getLogsForTag("Tugboat").any { "collector.baseUrl" in it.msg })
        }
    }

    @Test
    fun absoluteHttpCollectorUrlsAreAccepted() {
        for (url in listOf(
            "http://10.0.2.2:3000",
            "https://collector.example.com",
            "https://collector.example.com/",
            "HTTPS://collector.example.com/base/",
            "http://[::1]:3000",
            "http://collector_host:3000",
        )) {
            assertTrue(url, TugboatRuntime.isCollectorUrl(url))
        }
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
        Tugboat.activate("")
        Tugboat.activate("x")
        Tugboat.deactivate()
        Tugboat.deactivate()
        Thread { Tugboat.activate("from another thread") }.apply { start() }.join()
        Tugboat.stop()
        Tugboat.stop()
        Thread { Tugboat.setUserId("from another thread") }.apply { start() }.join()
        shadowOf(Looper.getMainLooper()).idle()
    }

    private fun activityCallbacks() = listSize(Application::class.java.getDeclaredField("mActivityLifecycleCallbacks"), application)

    private fun componentCallbacks() = (application as CallbackCountingApplication).componentCallbackCount()

    private fun processObservers() = (ProcessLifecycleOwner.get().lifecycle as LifecycleRegistry).observerCount

    private fun listSize(field: java.lang.reflect.Field, owner: Any): Int {
        field.isAccessible = true
        return (field.get(owner) as? Collection<*>)?.size ?: 0
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
