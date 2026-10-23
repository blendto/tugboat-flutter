package com.tugboat.android.views

import android.app.Activity
import com.tugboat.android.host.FakeClock
import com.tugboat.android.sdk.NavigationTracking
import com.tugboat.android.sdk.rowsController
import com.tugboat.android.views.navigation.NavigationObservation
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

/** session_start seeding after stop/start when stacks survive in process state. */
@RunWith(RobolectricTestRunner::class)
class SessionStartNavigationTest {
    private val sink = RecordingSink()
    private val frames = ManualFrames()

    @Before
    fun resetProcessNavigation() {
        NavigationObservation.resetForTests()
        NavigationObservation.setFrameSchedulerForTests(frames)
    }

    @Test
    fun stopStartSeedsResumedActivityWithoutAnotherResume() {
        val adapter = ViewsAdapter(
            application = context as android.app.Application,
            sink = sink,
            hostClock = FakeClock(),
            frames = frames,
            postNavigationFacts = true,
        )
        adapter.start()
        Robolectric.buildActivity(NavigationFactsTest.FirstActivity::class.java).setup()
        drainNavigation()
        adapter.stop()

        sink.batches.clear()
        val restarted = ViewsAdapter(
            application = context as android.app.Application,
            sink = sink,
            hostClock = FakeClock(),
            frames = frames,
            postNavigationFacts = true,
        )
        restarted.start()
        val seed = drainNavigation().last { it.getString("kind") == "session_start" }
        assertEquals("session_start", seed.getString("kind"))
        assertTrue(seed.getJSONArray("routes").length() >= 1)
        restarted.stop()
    }

    @Test
    fun navigateWhileStoppedThenStartSeedsCurrentStack() {
        val adapter = ViewsAdapter(
            application = context as android.app.Application,
            sink = sink,
            hostClock = FakeClock(),
            frames = frames,
            postNavigationFacts = true,
        )
        adapter.start()
        Robolectric.buildActivity(NavigationFactsTest.FirstActivity::class.java).setup()
        drainNavigation()
        adapter.stop()

        Robolectric.buildActivity(NavigationFactsTest.SecondActivity::class.java).setup()
        sink.batches.clear()
        adapter.start()
        val facts = drainNavigation()
        val activitySeed = facts.single {
            it.getString("kind") == "session_start" && it.getString("navigatorId").startsWith("activities:")
        }
        val routes = activitySeed.getJSONArray("routes")
        // The activity started while stopped is the seeded top.
        assertEquals(
            NavigationFactsTest.SecondActivity::class.java.name,
            routes.getJSONObject(routes.length() - 1).getString("name"),
        )
        adapter.stop()
    }

    @Test
    fun navControllerChangesWhileStoppedAreSeededOnStart() {
        val adapter = ViewsAdapter(
            application = context as android.app.Application,
            sink = sink,
            hostClock = FakeClock(),
            frames = frames,
            postNavigationFacts = true,
        )
        adapter.start()
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val controller = rowsController(activity)
        NavigationTracking.track(controller) { a, current, previous ->
            NavigationObservation.onNavDestination(a, current, previous)
        }
        drainNavigation()
        adapter.stop()

        controller.navigate("row/3")
        sink.batches.clear()
        adapter.start()
        val navSeed = drainNavigation().single {
            it.getString("kind") == "session_start" && it.getString("navigatorId").endsWith("/nav")
        }
        val routes = navSeed.getJSONArray("routes")
        assertEquals("row", routes.getJSONObject(routes.length() - 1).getString("name"))
        adapter.stop()
    }

    @Test
    fun resumedActivityAfterStopStartSendsNoExtraPush() {
        val adapter = ViewsAdapter(
            application = context as android.app.Application,
            sink = sink,
            hostClock = FakeClock(),
            frames = frames,
            postNavigationFacts = true,
        )
        adapter.start()
        val host = Robolectric.buildActivity(NavigationFactsTest.FirstActivity::class.java).setup()
        drainNavigation()
        adapter.stop()
        sink.batches.clear()
        adapter.start()
        drainNavigation()
        host.resume()
        assertTrue(drainNavigation().none { it.getString("kind") == "push" })
        adapter.stop()
    }

    private fun drainNavigation(): List<JSONObject> {
        while (frames.hasPending) frames.runFrame()
        return sink.batches.flatten().filter { it.type == "navigation" }.map { JSONObject(it.inputJson) }
    }
}
