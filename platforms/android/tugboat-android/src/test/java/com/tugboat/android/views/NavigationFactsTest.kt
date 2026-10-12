package com.tugboat.android.views

import android.app.Activity
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import com.tugboat.android.host.FakeClock
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

/** Navigation facts (stateful-engine.md 8.1) from real activity and fragment lifecycles. */
@RunWith(RobolectricTestRunner::class)
class NavigationFactsTest {
    private val sink = RecordingSink()
    private val frames = ManualFrames()
    private val adapter = ViewsAdapter(
        application = context as android.app.Application,
        sink = sink,
        hostClock = FakeClock(),
        frames = frames,
    ).apply { start() }

    @After
    fun stop() = adapter.stop()

    @Test
    fun activityStartIsAPushAndBackIsAPop() {
        val first = Robolectric.buildActivity(FirstActivity::class.java).setup()
        val push = navigation().single()
        assertEquals("push", push.getString("kind"))
        assertEquals("activities:${first.get().taskId}", push.getString("navigatorId"))
        val route = push.getJSONObject("route")
        assertEquals(FirstActivity::class.java.name, route.getString("name"))
        assertEquals("Activity", route.getString("type"))
        assertEquals("page", route.getString("overlayKind"))
        assertEquals(0, route.getInt("transitionMs"))
        assertFalse(push.has("departing"))

        first.pause()
        val second = Robolectric.buildActivity(SecondActivity::class.java).setup()
        first.stop()
        val covered = navigation().single()
        assertEquals("push", covered.getString("kind"))
        assertEquals(route.getString("instanceId"), covered.getJSONObject("departing").getString("instanceId"))

        second.get().finish()
        second.pause()
        first.restart().start().resume()
        second.stop().destroy()
        val back = navigation().single()
        assertEquals("pop", back.getString("kind"))
        assertEquals(route.getString("instanceId"), back.getJSONObject("route").getString("instanceId"))
        assertEquals(covered.getJSONObject("route").getString("instanceId"), back.getJSONObject("departing").getString("instanceId"))
    }

    @Test
    fun anActivityThatStartsAnotherAndFinishesIsReplaced() {
        val first = Robolectric.buildActivity(FirstActivity::class.java).setup()
        navigation()
        first.get().finish()
        first.pause()
        Robolectric.buildActivity(SecondActivity::class.java).setup()
        first.stop().destroy()
        assertEquals(listOf("replace"), navigation().map { it.getString("kind") })
    }

    @Test
    fun resumingAgainAfterBackgroundSendsNothing() {
        val first = Robolectric.buildActivity(FirstActivity::class.java).setup()
        navigation()
        first.pause().stop().restart().start().resume()
        assertTrue(navigation().isEmpty())
    }

    @Test
    fun fragmentTransactionsArePushReplaceAndPop() {
        val host = Robolectric.buildActivity(FragmentActivity::class.java).setup()
        val activityRoute = navigation().single().getJSONObject("route")
        val fm = host.get().supportFragmentManager

        fm.beginTransaction().add(android.R.id.content, TestFragment(), "home").commitNow()
        val home = navigation().single()
        assertEquals("push", home.getString("kind"))
        assertEquals("${activityRoute.getString("instanceId")}/fragments", home.getString("navigatorId"))
        assertEquals("activities:${host.get().taskId}", home.getString("parentNavigatorId"))
        assertEquals("home", home.getJSONObject("route").getString("name"))
        assertEquals("Fragment", home.getJSONObject("route").getString("type"))

        fm.beginTransaction().replace(android.R.id.content, TestFragment(), "detail").addToBackStack(null).commit()
        fm.executePendingTransactions()
        val detail = navigation().single()
        assertEquals("push", detail.getString("kind"))
        assertEquals("home", detail.getJSONObject("departing").getString("name"))

        fm.popBackStackImmediate()
        val back = navigation().single()
        assertEquals("pop", back.getString("kind"))
        assertEquals(home.getJSONObject("route").getString("instanceId"), back.getJSONObject("route").getString("instanceId"))

        fm.beginTransaction().replace(android.R.id.content, TestFragment(), "settings").commitNow()
        val settings = navigation().single()
        assertEquals("replace", settings.getString("kind"))
        assertEquals("settings", settings.getJSONObject("route").getString("name"))
        assertEquals("home", settings.getJSONObject("departing").getString("name"))
    }

    @Test
    fun untaggedFragmentsUseTheirClassNameAndRemovalPops() {
        val host = Robolectric.buildActivity(FragmentActivity::class.java).setup()
        navigation()
        val fm = host.get().supportFragmentManager
        fm.beginTransaction().add(android.R.id.content, TestFragment(), "base").commitNow()
        val top = TestFragment()
        fm.beginTransaction().add(android.R.id.content, top).commitNow()
        val pushed = navigation().last()
        assertEquals(TestFragment::class.java.name, pushed.getJSONObject("route").getString("name"))

        fm.beginTransaction().remove(top).commitNow()
        val removed = navigation().single()
        assertEquals("pop", removed.getString("kind"))
        assertEquals("base", removed.getJSONObject("route").getString("name"))
    }

    @Test
    fun recreatedActivitiesKeepTheirInstanceIdAndSendNothing() {
        val controller = Robolectric.buildActivity(FirstActivity::class.java).setup()
        val instanceId = navigation().single().getJSONObject("route").getString("instanceId")
        controller.recreate()
        assertTrue(navigation().isEmpty())

        controller.pause()
        Robolectric.buildActivity(SecondActivity::class.java).setup()
        val departing = navigation().single().getJSONObject("departing").getString("instanceId")
        assertEquals(instanceId, departing)
    }

    @Test
    fun instanceIdsAreDistinctPerInstance() {
        Robolectric.buildActivity(FirstActivity::class.java).setup()
        Robolectric.buildActivity(FirstActivity::class.java).setup()
        val ids = navigation().map { it.getJSONObject("route").getString("instanceId") }
        assertEquals(2, ids.size)
        assertNotEquals(ids[0], ids[1])
    }

    /** Runs a frame and returns the navigation inputs it posted. */
    private fun navigation(): List<JSONObject> {
        sink.batches.clear()
        while (frames.hasPending) frames.runFrame()
        return sink.batches.flatten().filter { it.type == "navigation" }.map { JSONObject(it.inputJson) }
    }

    class FirstActivity : Activity()

    class SecondActivity : Activity()

    class TestFragment : Fragment() {
        override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View =
            FrameLayout(inflater.context)
    }
}
