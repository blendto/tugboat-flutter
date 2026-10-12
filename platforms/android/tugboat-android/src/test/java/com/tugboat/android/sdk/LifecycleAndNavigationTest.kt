package com.tugboat.android.sdk

import android.app.Activity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.navigation.NavController
import androidx.navigation.createGraph
import androidx.navigation.testing.TestNavHostController
import androidx.navigation.NavDestination
import androidx.navigation.NavDestinationBuilder
import androidx.navigation.Navigator
import com.tugboat.android.views.navigation.NavEntry
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
    fun destinationChangesForwardTheCurrentEntryAndTheOneBelow() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val seen = ArrayList<Pair<NavEntry, NavEntry?>>()
        val controller = rowsController(activity)

        NavigationTracking.track(controller) { a, current, previous ->
            assertSame(activity, a)
            seen += current to previous
        }
        controller.navigate("row/3")

        assertEquals(listOf("rows", "row/{index}"), seen.map { it.first.route })
        assertEquals(null, seen[0].second)
        assertEquals(seen[0].first.id, seen[1].second?.id)
        assertEquals(controller.currentBackStackEntry?.id, seen[1].first.id)
    }

    @Test
    fun aControllerWithoutAGraphReportsNothingAndDoesNotThrow() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val seen = ArrayList<Activity>()
        NavigationTracking.track(NavController(activity)) { a, _, _ -> seen += a }
        assertEquals(emptyList<Activity>(), seen)
    }
}

/** A controller over `rows` and `row/{index}` test destinations, started at `rows`. */
internal fun rowsController(activity: Activity): TestNavHostController =
    TestNavHostController(activity).apply {
        graph = createGraph(startDestination = "rows") {
            // TestNavHostController's provider answers any navigator name with a test navigator.
            val navigator = provider.getNavigator<Navigator<NavDestination>>("test")
            destination(NavDestinationBuilder(navigator, "rows"))
            destination(NavDestinationBuilder(navigator, "row/{index}"))
        }
    }
