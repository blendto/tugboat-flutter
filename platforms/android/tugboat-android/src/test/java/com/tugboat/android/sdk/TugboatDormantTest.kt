package com.tugboat.android.sdk

import android.app.Activity
import android.app.Application
import android.os.Looper
import android.view.Window
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.navigation.NavController
import com.tugboat.android.AppInfo
import com.tugboat.android.CollectorConfig
import com.tugboat.android.Tugboat
import com.tugboat.android.TugboatConfig
import com.tugboat.android.TugboatLifecycleState
import com.tugboat.android.host.FakeEngineTransport
import com.tugboat.android.views.callback.CallbackChain
import org.junit.After
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

/**
 * The default config ([TugboatConfig.enabled] `false`) is dormant: no engine,
 * window callbacks, component callbacks, or process observers; only the
 * process-scoped activity lifecycle callbacks. Formerly the W5a kill-switch
 * tests (`enabled = false` installed nothing).
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = CallbackCountingApplication::class)
class TugboatDormantTest {
    private val application = RuntimeEnvironment.getApplication() as CallbackCountingApplication
    private val disabledConfig = TugboatConfig(
        collector = CollectorConfig("http://10.0.2.2:3000", "key"),
        app = AppInfo("Sample", "1.0.0", "1", "com.example.sample", "install-1"),
    )
    private val enabledConfig = disabledConfig.copy(enabled = true)

    @Before
    fun setUp() {
        Tugboat.resetForTests()
    }

    @After
    fun tearDown() {
        Tugboat.stop()
        shadowOf(Looper.getMainLooper()).idle()
        Tugboat.resetForTests()
    }

    @Test
    fun defaultConfigIsDormantAndRecordsNothing() {
        assertFalse(TugboatConfig(disabledConfig.collector, disabledConfig.app).enabled)
        var opened = false
        Tugboat.openTransportForTesting = {
            opened = true
            FakeEngineTransport()
        }
        Tugboat.start(application, disabledConfig)
        Tugboat.eventHook(source = "analytics").record("WHILE_DORMANT")
        Tugboat.beginNetworkCall("GET", "/dormant").complete(statusCode = 200)
        shadowOf(Looper.getMainLooper()).idle()
        assertFalse(opened)
        assertEquals(TugboatLifecycleState.DORMANT, Tugboat.lifecycleState)
        assertFalse(Tugboat.isActivated)
        assertFalse(Tugboat.isAcceptingEvidence)
    }

    @Test
    fun dormantStartRegistersOnlyTheProcessScopedActivityCallbacks() {
        val before = activityLifecycleCallbackCount(application)
        Tugboat.openTransportForTesting = { FakeEngineTransport() }
        Tugboat.start(application, disabledConfig)
        shadowOf(Looper.getMainLooper()).idle()
        // Navigation observation (stacks, live activities); no session callbacks.
        assertEquals(before + 1, activityLifecycleCallbackCount(application))
    }

    @Test
    fun stateSetWhileDormantFeedsTheNextActivatedSession() {
        val transport = FakeEngineTransport()
        Tugboat.openTransportForTesting = { transport }
        Tugboat.start(application, disabledConfig)
        Tugboat.setUserId("u-42")
        Tugboat.setTraits(mapOf("plan" to "pro"))
        val hook = Tugboat.eventHook(source = "analytics")
        shadowOf(Looper.getMainLooper()).idle()

        Tugboat.activate("act-1")
        shadowOf(Looper.getMainLooper()).idle()
        hook.record("AFTER_ENABLE")

        awaitUntil { transport.submitted.any { it.contains("AFTER_ENABLE") } }
        val identity = transport.submitted.map(::JSONObject).first { it.getString("type") == "identity.set" }
        assertEquals("u-42", identity.getJSONObject("input").getString("userId"))
        val traits = transport.submitted.map(::JSONObject).first { it.getString("type") == "traits.set" }
        assertTrue(traits.toString().contains("\"plan\":\"pro\""))
    }

    @Test
    fun enabledStartRegistersActivityLifecycleCallbacks() {
        val before = activityLifecycleCallbackCount(application)
        Tugboat.openTransportForTesting = { FakeEngineTransport() }
        Tugboat.start(application, enabledConfig)
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(activityLifecycleCallbackCount(application) > before)
        Tugboat.stop()
    }

    @Test
    fun dormantStartRegistersNoComponentCallbacksOrProcessLifecycleObservers() {
        val callbacksBefore = application.componentCallbackCount()
        val observersBefore = processLifecycleObserverCount()
        Tugboat.openTransportForTesting = { FakeEngineTransport() }
        Tugboat.start(application, disabledConfig)
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(callbacksBefore, application.componentCallbackCount())
        assertEquals(observersBefore, processLifecycleObserverCount())
        Tugboat.stop()
    }

    @Test
    fun enabledStartRegistersComponentCallbacksAndProcessLifecycleObservers() {
        val callbacksBefore = application.componentCallbackCount()
        val observersBefore = processLifecycleObserverCount()
        Tugboat.openTransportForTesting = { FakeEngineTransport() }
        Tugboat.start(application, enabledConfig)
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(application.componentCallbackCount() > callbacksBefore)
        assertTrue(processLifecycleObserverCount() > observersBefore)
        Tugboat.stop()
    }

    @Test
    fun dormantStartLeavesTheWindowCallbackUntouched() {
        Tugboat.openTransportForTesting = { FakeEngineTransport() }
        Tugboat.start(application, disabledConfig)
        shadowOf(Looper.getMainLooper()).idle()

        val controller = Robolectric.buildActivity(Activity::class.java).create().start().resume()
        val window: Window = controller.get().window
        assertSame(controller.get(), window.callback)

        Tugboat.stop()
    }

    @Test
    fun enabledStartWrapsTheWindowCallback() {
        Tugboat.openTransportForTesting = { FakeEngineTransport() }
        Tugboat.start(application, enabledConfig)
        shadowOf(Looper.getMainLooper()).idle()

        val activity = Robolectric.buildActivity(Activity::class.java).create().start().resume().get()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(1, CallbackChain.countTugboat(activity.window.callback))

        Tugboat.stop()
        shadowOf(Looper.getMainLooper()).idle()
        assertSame(activity, activity.window.callback)
    }

    @Test
    fun dormantStartThenTrackNavigationKeepsTheControllerWithoutAnEngine() {
        var opened = false
        Tugboat.openTransportForTesting = {
            opened = true
            FakeEngineTransport()
        }
        Tugboat.start(application, disabledConfig)
        shadowOf(Looper.getMainLooper()).idle()

        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val controller = rowsController(activity)
        val before = destinationListenerCount(controller)
        Tugboat.trackNavigation(controller)
        controller.navigate("row/1")
        shadowOf(Looper.getMainLooper()).idle()
        // The stack is kept for the next session's seed; nothing is sent.
        assertEquals(before + 1, destinationListenerCount(controller))
        assertFalse(opened)

        Tugboat.stop()
    }

    private fun activityLifecycleCallbackCount(application: Application): Int {
        val field = Application::class.java.getDeclaredField("mActivityLifecycleCallbacks")
        field.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        return (field.get(application) as? ArrayList<*>)?.size ?: 0
    }

    private fun processLifecycleObserverCount(): Int {
        val registry = ProcessLifecycleOwner.get().lifecycle as LifecycleRegistry
        return registry.observerCount
    }

    private fun destinationListenerCount(controller: NavController): Int {
        val field = NavController::class.java.getDeclaredField("onDestinationChangedListeners")
        field.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        return (field.get(controller) as? Collection<*>)?.size ?: 0
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
