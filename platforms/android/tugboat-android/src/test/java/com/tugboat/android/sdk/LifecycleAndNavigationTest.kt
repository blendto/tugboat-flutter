package com.tugboat.android.sdk

import android.app.Activity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.navigation.NavController
import androidx.navigation.NavDestination
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class LifecycleAndNavigationTest {
    private class Owner : LifecycleOwner {
        val registry = LifecycleRegistry.createUnsafe(this)
        override val lifecycle: Lifecycle
            get() = registry
    }

    @Test
    fun processEventsMapToEngineStatesAndStopDetaches() {
        val owner = Owner()
        val states = ArrayList<String>()
        val bridge = AppLifecycleBridge(post = { states += it }, owner = { owner })
        bridge.start()

        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_CREATE)
        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_START)
        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_RESUME)
        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE)
        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
        bridge.stop()
        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_START)
        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_RESUME)

        assertEquals(listOf("resumed", "inactive", "paused"), states)
    }

    @Test
    fun startingWhileResumedReplaysResumed() {
        val owner = Owner()
        owner.registry.currentState = Lifecycle.State.RESUMED
        val states = ArrayList<String>()
        AppLifecycleBridge(post = { states += it }, owner = { owner }).start()

        assertEquals(listOf("resumed"), states)
    }

    @Test
    fun destinationsAreForwardedWithTheirActivityRouteAndId() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val seen = ArrayList<Triple<Activity, String?, Int>>()
        val forwarder = DestinationForwarder(activity) { a, route, id -> seen += Triple(a, route, id) }
        val destination = NavDestination("test").apply {
            id = 42
            route = "checkout/{orderId}"
        }

        forwarder.onDestinationChanged(NavController(activity), destination, null)

        assertSame(activity, seen.single().first)
        assertEquals("checkout/{orderId}", seen.single().second)
        assertEquals(42, seen.single().third)
    }

    @Test
    fun trackNavigationReportsTheCurrentDestinationOfAnActivityController() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val seen = ArrayList<Activity>()
        // A controller without a graph has no destination yet; tracking must not throw.
        NavigationTracking.track(NavController(activity)) { a, _, _ -> seen += a }
        assertEquals(emptyList<Activity>(), seen)
    }
}
