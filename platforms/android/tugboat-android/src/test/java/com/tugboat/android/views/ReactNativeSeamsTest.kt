package com.tugboat.android.views

import android.app.Application
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import com.tugboat.android.Tugboat
import com.tugboat.android.adapter.TugboatAdapters
import com.tugboat.android.host.FakeClock
import com.tugboat.android.views.identity.AndroidResourceNames
import com.tugboat.android.views.identity.FallbackNames
import com.tugboat.android.views.identity.AnchorResolver
import com.tugboat.android.views.navigation.NavigationObservation
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

/** The seams the React Native SDK needs: early install, `setScreen`, a view-name provider, a fragment filter. */
@RunWith(RobolectricTestRunner::class)
class ReactNativeSeamsTest {
    private val sink = RecordingSink()
    private val frames = ManualFrames()
    private val app = context as Application

    @Before
    fun setUp() {
        NavigationObservation.resetForTests()
        NavigationObservation.setFrameSchedulerForTests(frames)
        sink.batches.clear()
    }

    @After
    fun clearSeams() {
        TugboatAdapters.setViewNameProvider(null)
        TugboatAdapters.setFragmentFilter(null)
        NavigationObservation.resetForTests()
    }

    private fun startAdapter() = ViewsAdapter(
        application = app,
        sink = sink,
        hostClock = FakeClock(),
        frames = frames,
        postNavigationFacts = true,
    ).apply { start() }

    @Test
    fun anActivityCreatedAfterInstallButBeforeStartIsSeenByALaterSession() {
        TugboatAdapters.install(app)
        TugboatAdapters.install(app) // idempotent
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        assertSame(activity, NavigationObservation.resumedActivity())

        val adapter = startAdapter()
        while (frames.hasPending) frames.runFrame()
        val seed = sink.batches.flatten().filter { it.type == "navigation" }.map { JSONObject(it.inputJson) }.single { it.getString("kind") == "session_start" && it.getString("navigatorId").startsWith("activities:") }
        val routes = seed.getJSONArray("routes")
        assertEquals(FragmentActivity::class.java.name, routes.getJSONObject(routes.length() - 1).getString("name"))
        adapter.stop()
    }

    @Test
    fun withoutInstallAnEarlierActivityIsNotSeen() {
        Robolectric.buildActivity(FragmentActivity::class.java).setup()
        assertNull(NavigationObservation.resumedActivity())
    }

    @Test
    fun setScreenIsPushThenPushThenPopAndSetsTheRouteKey() {
        val adapter = startAdapter()
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        navigation()

        Tugboat.setScreen("Main/Feed", "k1")
        val feed = navigation().single()
        assertEquals("push", feed.getString("kind"))
        assertEquals("Main/Feed", feed.getJSONObject("route").getString("name"))
        assertEquals("k1", feed.getJSONObject("route").getString("instanceId"))
        assertEquals("NavDestination", feed.getJSONObject("route").getString("type"))
        assertEquals("Main/Feed", routeKeyOf(activity))

        Tugboat.setScreen("Main/Detail", "k2")
        val detail = navigation().single()
        assertEquals("push", detail.getString("kind"))
        assertEquals("k1", detail.getJSONObject("departing").getString("instanceId"))
        assertEquals("Main/Detail", routeKeyOf(activity))

        Tugboat.setScreen("Main/Feed", "k1")
        val back = navigation().single()
        assertEquals("pop", back.getString("kind"))
        assertEquals("k1", back.getJSONObject("route").getString("instanceId"))
        assertEquals("Main/Feed", routeKeyOf(activity))

        // The instance id defaults to the name.
        Tugboat.setScreen("Settings")
        assertEquals("Settings", navigation().single().getJSONObject("route").getString("instanceId"))
        adapter.stop()
    }

    @Test
    fun setScreenWithNoResumedActivityDoesNothing() {
        val adapter = startAdapter()
        Tugboat.setScreen("Main/Feed")
        assertTrue(navigation().isEmpty())
        adapter.stop()
    }

    @Test
    fun aProvidedNameIsThePathSegmentAndTheAliasOnlyWhenTheResourceIdHasNone() {
        // React Native views each have a generated id, which the alias's uniqueness check counts.
        val button = Button(context).apply { id = View.generateViewId() }
        val root = FrameLayout(context).apply { addView(button, FrameLayout.LayoutParams(400, 100)) }
        layOut(root)
        val anchors = AnchorResolver(
            FallbackNames(AndroidResourceNames(context.resources)) { TugboatAdapters.viewNameProvider },
            FixedRoutes(root),
        )
        assertEquals("Button#0", anchors.anchorFor(button, root)!!.canonicalPath)

        TugboatAdapters.setViewNameProvider { view -> if (view === button) "pay" else null }
        val named = anchors.anchorFor(button, root)!!
        assertEquals("Button#pay", named.canonicalPath)
        assertEquals("pay", named.tag)

        // A resource id wins over the provider.
        val generated = button.id
        button.id = android.R.id.button1
        assertEquals("Button#button1", anchors.anchorFor(button, root)!!.canonicalPath)

        // A throwing provider changes nothing.
        button.id = generated
        TugboatAdapters.setViewNameProvider { error("boom") }
        assertEquals("Button#0", anchors.anchorFor(button, root)!!.canonicalPath)
    }

    @Test
    fun aStartedViewsAdapterNamesATappedViewFromTheProvider() {
        val harness = DialogHarness()
        try {
            TugboatAdapters.setViewNameProvider { view -> if (view is Button) "pay" else null }
            val activity = Robolectric.buildActivity(ButtonHost::class.java).setup().get()
            harness.drainFacts()
            tapThrough(activity.window, activity.button)
            val anchor = harness.pointerUps().single().tapAnchor()
            assertEquals("Button#pay", anchor.getString("canonicalPath"))
            assertEquals("pay", anchor.getJSONObject("fingerprintParts").getString("tag"))
        } finally {
            harness.stop()
        }
    }

    @Test
    fun aFilterThatChangesWhileAFragmentIsShownStillLetsItLeaveTheStack() {
        val adapter = startAdapter()
        val host = Robolectric.buildActivity(FragmentActivity::class.java).setup()
        val fm = host.get().supportFragmentManager
        fm.beginTransaction().add(android.R.id.content, ShownFragment(), "a").commitNow()
        navigation()
        TugboatAdapters.setFragmentFilter { it == ShownFragment::class.java.name }
        fm.beginTransaction().remove(fm.findFragmentByTag("a")!!).commitNow()
        TugboatAdapters.setFragmentFilter(null)
        navigation()
        // The removed fragment left the stack: the next one is a push with nothing departing.
        fm.beginTransaction().add(android.R.id.content, ShownFragment(), "b").commitNow()
        val next = navigation().single()
        assertEquals("push", next.getString("kind"))
        assertEquals(false, next.has("departing"))
        adapter.stop()
    }

    @Test
    fun aThrowingFilterIsTreatedAsNotFiltered() {
        val adapter = startAdapter()
        val host = Robolectric.buildActivity(FragmentActivity::class.java).setup()
        navigation()
        TugboatAdapters.setFragmentFilter { error("boom") }
        host.get().supportFragmentManager.beginTransaction().add(android.R.id.content, ShownFragment(), "shown").commitNow()
        assertEquals("shown", navigation().single().getJSONObject("route").getString("name"))
        adapter.stop()
    }

    @Test
    fun aBlankScreenNameIsIgnored() {
        val adapter = startAdapter()
        Robolectric.buildActivity(FragmentActivity::class.java).setup()
        navigation()
        Tugboat.setScreen("")
        Tugboat.setScreen("  ", "x")
        assertTrue(navigation().isEmpty())
        adapter.stop()
    }

    @Test
    fun aFilteredFragmentSendsNoFactAndAnUnfilteredOneStillDoes() {
        val adapter = startAdapter()
        val host = Robolectric.buildActivity(FragmentActivity::class.java).setup()
        navigation()
        val fm = host.get().supportFragmentManager
        TugboatAdapters.setFragmentFilter { it == HiddenFragment::class.java.name }

        fm.beginTransaction().add(android.R.id.content, HiddenFragment(), "hidden").commitNow()
        assertTrue(navigation().isEmpty())
        assertEquals("FragmentActivity", routeKeyOf(host.get()).substringAfterLast('.'))

        fm.beginTransaction().replace(android.R.id.content, ShownFragment(), "shown").commitNow()
        val shown = navigation().single()
        assertEquals("shown", shown.getJSONObject("route").getString("name"))
        assertEquals("push", shown.getString("kind"))
        adapter.stop()
    }

    private fun routeKeyOf(activity: android.app.Activity): String =
        NavigationObservation.routesAccessor.routeFor(activity.findViewById(android.R.id.content))!!.value

    private fun navigation(): List<JSONObject> {
        sink.batches.clear()
        while (frames.hasPending) frames.runFrame()
        return sink.batches.flatten().filter { it.type == "navigation" }.map { JSONObject(it.inputJson) }
    }

    class ButtonHost : android.app.Activity() {
        lateinit var button: Button

        override fun onCreate(savedInstanceState: android.os.Bundle?) {
            super.onCreate(savedInstanceState)
            button = Button(this).apply { id = View.generateViewId() }
            setContentView(FrameLayout(this).apply { addView(button, FrameLayout.LayoutParams(100, 100)) })
        }
    }

    class HiddenFragment : Fragment() {
        override fun onCreateView(inflater: android.view.LayoutInflater, container: android.view.ViewGroup?, state: android.os.Bundle?) =
            View(requireContext())
    }

    class ShownFragment : Fragment() {
        override fun onCreateView(inflater: android.view.LayoutInflater, container: android.view.ViewGroup?, state: android.os.Bundle?) =
            View(requireContext())
    }
}
