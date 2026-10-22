package com.tugboat.android.views

import android.app.Activity
import com.tugboat.android.host.FakeClock
import com.tugboat.android.sdk.NavigationTracking
import com.tugboat.android.sdk.rowsController
import com.tugboat.android.views.navigation.NavigationProcessState
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

/** `NavController` destinations as `navigation` facts on a navigator nested under the activity's. */
@RunWith(RobolectricTestRunner::class)
class ControllerNavigationFactsTest {
    private val sink = RecordingSink()
    private val frames = ManualFrames()
    private lateinit var adapter: ViewsAdapter

    @Before
    fun setUp() {
        NavigationProcessState.resetForTests()
        sink.batches.clear()
        adapter = ViewsAdapter(
            application = context as android.app.Application,
            sink = sink,
            hostClock = FakeClock(),
            frames = frames,
            postNavigationFacts = true,
        ).apply { start() }
    }

    @After
    fun stop() = adapter.stop()

    @Test
    fun navigatingToARowAndBackIsAPushThenAPopWithNormalizedNames() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val activityPush = navigation().single()
        assertEquals("session_start", activityPush.getString("kind"))
        val activityNavigator = activityPush.getString("navigatorId")
        val activityRoute = activityPush.bottomRouteInstanceId()

        val controller = rowsController(activity)
        NavigationTracking.track(controller) { a, current, previous -> adapter.onNavDestination(a, current, previous) }
        val start = navigation().single()
        assertEquals("session_start", start.getString("kind"))
        controller.navigate("row/3")
        val push = navigation().single()
        assertEquals("push", push.getString("kind"))
        controller.popBackStack()
        val pop = navigation().single()

        for (fact in listOf(start, push, pop)) {
            assertEquals("$activityRoute/nav", fact.getString("navigatorId"))
            assertEquals(activityNavigator, fact.getString("parentNavigatorId"))
            val route = if (fact.getString("kind") == "session_start") {
                fact.getJSONArray("routes").getJSONObject(0)
            } else {
                fact.getJSONObject("route")
            }
            assertEquals("NavDestination", route.getString("type"))
            assertEquals("page", route.getString("overlayKind"))
            assertEquals(0, route.getInt("transitionMs"))
        }
        assertEquals("rows", start.getJSONArray("routes").getJSONObject(0).getString("name"))
        assertFalse(start.has("departing"))

        assertEquals("row", push.getJSONObject("route").getString("name"))
        assertEquals(
            start.getJSONArray("routes").getJSONObject(0).getString("instanceId"),
            push.getJSONObject("departing").getString("instanceId"),
        )

        assertEquals("pop", pop.getString("kind"))
        assertEquals("rows", pop.getJSONObject("route").getString("name"))
        assertEquals(
            start.getJSONArray("routes").getJSONObject(0).getString("instanceId"),
            pop.getJSONObject("route").getString("instanceId"),
        )
        assertEquals(push.getJSONObject("route").getString("instanceId"), pop.getJSONObject("departing").getString("instanceId"))
    }

    @Test
    fun aNavigateThatPopsTheTopIsAReplace() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        navigation()
        val controller = rowsController(activity)
        NavigationTracking.track(controller) { a, current, previous -> adapter.onNavDestination(a, current, previous) }
        controller.navigate("row/1")
        navigation()

        controller.navigate("row/2") { popUpTo("row/{index}") { inclusive = true } }

        val replace = navigation().single()
        assertEquals("replace", replace.getString("kind"))
        assertEquals("row", replace.getJSONObject("route").getString("name"))
    }

    @Test
    fun aRecreatedControllerShowingTheSameEntryReportsNothing() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        navigation()
        val controller = rowsController(activity)
        NavigationTracking.track(controller) { a, current, previous -> adapter.onNavDestination(a, current, previous) }
        navigation()

        // The same back-stack entry reported again (as after a recreation restores it).
        val entry = checkNotNull(controller.currentBackStackEntry)
        adapter.onNavDestination(
            activity,
            com.tugboat.android.views.navigation.NavEntry(entry.id, entry.destination.route, entry.destination.id),
            null,
        )

        assertTrue(navigation().isEmpty())
    }

    private fun navigation(): List<JSONObject> {
        sink.batches.clear()
        while (frames.hasPending) frames.runFrame()
        return sink.batches.flatten().filter { it.type == "navigation" }.map { JSONObject(it.inputJson) }
    }
}
