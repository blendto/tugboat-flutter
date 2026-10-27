package com.tugboat.android.sdk

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.Looper
import android.view.MotionEvent
import com.tugboat.android.AppInfo
import com.tugboat.android.CollectorConfig
import com.tugboat.android.Tugboat
import com.tugboat.android.TugboatConfig
import com.tugboat.android.TugboatLifecycleState
import com.tugboat.android.TugboatLifecycleState.ACTIVE
import com.tugboat.android.TugboatLifecycleState.DORMANT
import com.tugboat.android.TugboatLifecycleState.STARTING
import com.tugboat.android.TugboatLifecycleState.STOPPING
import com.tugboat.android.capture.ForegroundWindow
import com.tugboat.android.host.FakeEngineTransport
import com.tugboat.android.views.callback.CallbackChain
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLog
import java.time.Duration
import java.util.concurrent.CopyOnWriteArrayList

/**
 * `Tugboat.activate` / `deactivate` / `stop` against Flutter's lifecycle
 * (`lifecycle.dart`), driven through real sessions on fake engines.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class TugboatActivationTest {
    private val application = RuntimeEnvironment.getApplication()
    private val config = TugboatConfig(
        collector = CollectorConfig("http://10.0.2.2:3000", "key"),
        app = AppInfo("Sample", "1.0.0", "1", "com.example.sample", "install-1"),
    )
    private val transports = CopyOnWriteArrayList<FakeEngineTransport>()
    private val states = CopyOnWriteArrayList<TugboatLifecycleState>()

    @Before
    fun setUp() {
        Tugboat.resetForTests()
        ShadowLog.clear()
        Tugboat.openTransportForTesting = { FakeEngineTransport().also(transports::add) }
        Tugboat.lifecycleObserverForTesting = { states += it }
    }

    @After
    fun tearDown() {
        Tugboat.stop()
        idle()
        Tugboat.resetForTests()
    }

    @Test
    fun activateFromDormantStartsOneSessionCarryingTheId() {
        Tugboat.start(application, config)
        idle()
        assertEquals(DORMANT, Tugboat.lifecycleState)
        assertTrue(transports.isEmpty())

        Tugboat.activate("a")
        idle()

        val start = awaitSessionStart(0)
        assertEquals("a", start.getJSONObject("input").getString("activationRequestId"))
        assertEquals(1, transports.size)
        assertEquals(ACTIVE, Tugboat.lifecycleState)
        assertTrue(Tugboat.isActivated)
        assertEquals("a", Tugboat.activationRequestId)
    }

    @Test
    fun theSameIdTwiceIsOneSessionAndANewIdReplacesItWithoutStopping() {
        Tugboat.start(application, config)
        Tugboat.activate("a")
        idle()
        Tugboat.activate("a")
        idle()
        assertEquals(1, transports.size)
        val first = awaitSessionStart(0)

        // Off the main thread: the new id and `starting` are visible before main runs.
        Thread { Tugboat.activate("b") }.apply { start() }.join()
        assertEquals("b", Tugboat.activationRequestId)
        assertEquals(STARTING, Tugboat.lifecycleState)
        idle()

        awaitUntil { "session.end" in types(transports[0]) }
        val second = awaitSessionStart(1)
        assertEquals("b", second.getJSONObject("input").getString("activationRequestId"))
        assertTrue(
            second.getJSONObject("input").getInt("sessionEpoch") > first.getJSONObject("input").getInt("sessionEpoch"),
        )
        assertEquals(2, transports.size)
        assertEquals(ACTIVE, Tugboat.lifecycleState)
        assertFalse("states: $states", STOPPING in states)
    }

    @Test
    fun deactivateFencesEvidenceOnTheCallingThreadAndEndsTheSession() {
        Tugboat.start(application, config.copy(enabled = true))
        idle()
        awaitSessionStart(0)
        assertEquals(ACTIVE, Tugboat.lifecycleState)
        assertFalse(Tugboat.isActivated)
        val hook = Tugboat.eventHook(source = "test")

        var acceptingAfterDeactivate = true
        Thread {
            Tugboat.deactivate()
            acceptingAfterDeactivate = Tugboat.isAcceptingEvidence
            Tugboat.beginNetworkCall("GET", "/fenced").complete(statusCode = 200)
            hook.record("FENCED_EVENT")
        }.apply { start() }.join()
        assertFalse(acceptingAfterDeactivate)
        assertEquals(STOPPING, Tugboat.lifecycleState)
        idle()

        awaitUntil { "session.end" in types(transports[0]) }
        assertEquals(DORMANT, Tugboat.lifecycleState)
        assertTrue(transports[0].submitted.none { it.contains("/fenced") || it.contains("FENCED_EVENT") })

        // `enabled = true` does not start a session again until the next activate.
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))
        assertEquals(1, transports.size)
        Tugboat.activate("c")
        idle()
        assertEquals("c", awaitSessionStart(1).getJSONObject("input").getString("activationRequestId"))
    }

    @Test
    fun anActivateBeforeStartAppliesAtStartAndStopForgetsIt() {
        Tugboat.activate("early")
        assertEquals(STARTING, Tugboat.lifecycleState)
        assertTrue(Tugboat.isActivated)
        idle()
        assertTrue(transports.isEmpty())

        Tugboat.start(application, config)
        idle()
        assertEquals("early", awaitSessionStart(0).getJSONObject("input").getString("activationRequestId"))
        assertEquals(ACTIVE, Tugboat.lifecycleState)

        Tugboat.stop()
        idle()
        assertEquals(DORMANT, Tugboat.lifecycleState)
        assertNull(Tugboat.activationRequestId)
        Tugboat.start(application, config)
        idle()
        assertEquals(1, transports.size)
        assertEquals(DORMANT, Tugboat.lifecycleState)
    }

    @Test
    fun anActivateAfterStopIsKeptForTheNextStart() {
        Tugboat.start(application, config.copy(enabled = true))
        idle()
        Tugboat.stop()
        Tugboat.activate("late")
        idle()
        assertEquals(1, transports.size)

        Tugboat.start(application, config)
        idle()
        assertEquals("late", awaitSessionStart(1).getJSONObject("input").getString("activationRequestId"))
    }

    @Test
    fun anActivityAlreadyResumedAtActivateIsRecordedAndSeeded() {
        Tugboat.start(application, config)
        idle()
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        idle()
        assertSame(activity, activity.window.callback)

        Tugboat.activate("a")
        idle()
        assertEquals(1, CallbackChain.countTugboat(activity.window.callback))
        activity.window.callback.dispatchTouchEvent(MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, 10f, 10f, 0))
        activity.window.callback.dispatchTouchEvent(MotionEvent.obtain(0, 1, MotionEvent.ACTION_UP, 10f, 10f, 0))
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(100))

        awaitUntil { messages(transports[0]).any { it.getString("type") == "input.pointer" } }
        val seed = messages(transports[0]).single {
            it.getString("type") == "navigation" &&
                it.getJSONObject("input").getString("kind") == "session_start" &&
                it.getJSONObject("input").getString("navigatorId").startsWith("activities:")
        }.getJSONObject("input")
        val routes = seed.getJSONArray("routes")
        assertEquals(Activity::class.java.name, routes.getJSONObject(routes.length() - 1).getString("name"))
        // The foreground window adopted it: its boundary is reported at once.
        assertTrue(messages(transports[0]).any { it.getString("type") == "surface" })
    }

    @Test
    fun theForegroundWindowAdoptsTheResumedActivityAtStartSoCapturesDoNotWait() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val resumed = ArrayList<Activity>()
        val foreground = ForegroundWindow(
            application,
            resumedActivity = { activity },
            onResumed = { resumed += it },
            onBoundary = {},
        )
        foreground.start()
        try {
            assertSame(activity.window, foreground.window)
            var done = false
            foreground.awaitWindow(timeoutMs = 60_000) { done = true }
            assertTrue("awaitWindow answered at once", done)
            assertEquals(listOf(activity), resumed)
        } finally {
            foreground.stop()
        }
    }

    @Test
    fun aControllerTrackedWhileDormantSeedsTheActivatedSession() {
        Tugboat.start(application, config)
        idle()
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val controller = rowsController(activity)
        Tugboat.trackNavigation(controller)
        idle()
        controller.navigate("row/1")
        controller.navigate("row/2")

        Tugboat.activate("a")
        idle()

        awaitSessionStart(0)
        val navSeed = messages(transports[0]).single {
            it.getString("type") == "navigation" &&
                it.getJSONObject("input").getString("kind") == "session_start" &&
                it.getJSONObject("input").getString("navigatorId").endsWith("/nav")
        }.getJSONObject("input")
        val names = navSeed.getJSONArray("routes").let { routes -> (0 until routes.length()).map { routes.getJSONObject(it).getString("name") } }
        assertEquals(listOf("rows", "row", "row"), names)
    }

    @Test
    fun launchAndHealthLinesFollowAnActivationWhileResumed() {
        Tugboat.start(application, config)
        idle()
        Robolectric.buildActivity(
            Activity::class.java,
            Intent().putExtras(Bundle().apply { putString(LaunchExtraKeys.EMIT_SCENE_INVENTORY, "1") }),
        ).setup()
        idle()
        assertTrue(logLines("TUGBOAT_LAUNCH").isEmpty())

        Tugboat.activate("h")
        idle()
        assertEquals(1, logLines("TUGBOAT_LAUNCH").size)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(LaunchCorrelation.HEALTH_DELAY_MS))
        val health = JSONObject(logLines("TUGBOAT_HEALTH").single().removePrefix("TUGBOAT_HEALTH ").trim())
        assertEquals("active", health.getString("lifecycle"))
        assertEquals("h", health.getString("activationRequestId"))
        assertTrue(health.has("captureSessionId"))
    }

    private fun logLines(prefix: String): List<String> =
        ShadowLog.getLogsForTag(LaunchCorrelation.TAG).map { it.msg }.filter { it.startsWith(prefix) }

    private fun awaitSessionStart(index: Int): JSONObject {
        awaitUntil { transports.size > index && "session.start" in types(transports[index]) }
        return messages(transports[index]).first { it.getString("type") == "session.start" }
    }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    private fun awaitUntil(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (!condition() && System.currentTimeMillis() < deadline) {
            idle()
            Thread.sleep(10)
        }
        assertTrue("timed out", condition())
    }
}

/** Every message [transport] received, batches expanded. */
internal fun messages(transport: FakeEngineTransport): List<JSONObject> =
    transport.submitted.map(::JSONObject).flatMap { json ->
        val batch = json.optJSONArray("messages") ?: return@flatMap listOf(json)
        (0 until batch.length()).map(batch::getJSONObject)
    }

internal fun types(transport: FakeEngineTransport): List<String> = messages(transport).map { it.optString("type") }
