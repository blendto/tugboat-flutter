package com.tugboat.android.views

import android.app.Activity
import com.tugboat.android.Tugboat
import com.tugboat.android.host.FakeClock
import com.tugboat.android.sdk.rowsController
import com.tugboat.android.views.navigation.NavigationObservation
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
        val adapter = adapter()
        adapter.start()
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val controller = rowsController(activity)
        Tugboat.trackNavigation(controller)
        drainNavigation()
        adapter.stop()

        controller.navigate("row/3")
        sink.batches.clear()
        adapter.start()
        val navSeed = drainNavigation().single {
            it.getString("kind") == "session_start" && it.getString("navigatorId").endsWith("/nav")
        }
        val routes = navSeed.getJSONArray("routes")
        val top = routes.getJSONObject(routes.length() - 1)
        assertEquals("row", top.getString("name"))

        sink.batches.clear()
        controller.navigate("row/4")
        val next = drainNavigation().single { it.getString("navigatorId") == navSeed.getString("navigatorId") }
        assertEquals("push", next.getString("kind"))
        assertEquals(top.getString("instanceId"), next.getJSONObject("departing").getString("instanceId"))
        adapter.stop()
    }

    @Test
    fun navControllerTrackedBeforeTheFirstStartIsNotSeeded() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val controller = rowsController(activity)
        Tugboat.trackNavigation(controller)
        controller.navigate("row/3")

        val adapter = adapter()
        adapter.start()
        assertTrue(
            drainNavigation().none {
                it.getString("kind") == "session_start" && it.getString("navigatorId").endsWith("/nav")
            },
        )

        controller.navigate("row/4")
        val next = drainNavigation().single { it.getString("navigatorId").endsWith("/nav") }
        assertEquals("push", next.getString("kind"))
        // The stack recorded before observation installed was discarded.
        assertFalse(next.has("departing"))
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

    private fun adapter() = ViewsAdapter(
        application = context as android.app.Application,
        sink = sink,
        hostClock = FakeClock(),
        frames = frames,
        postNavigationFacts = true,
    )

    private fun drainNavigation(): List<JSONObject> {
        while (frames.hasPending) frames.runFrame()
        return sink.batches.flatten().filter { it.type == "navigation" }.map { JSONObject(it.inputJson) }
    }
}
