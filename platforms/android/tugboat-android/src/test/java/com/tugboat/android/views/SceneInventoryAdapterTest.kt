package com.tugboat.android.views

import android.app.Application
import android.os.Bundle
import android.os.Looper
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.FragmentContainerView
import androidx.lifecycle.Lifecycle
import androidx.viewpager2.adapter.FragmentStateAdapter
import androidx.viewpager2.widget.ViewPager2
import com.tugboat.android.host.FakeClock
import com.tugboat.android.views.inventory.SceneInventoryFactContract
import com.tugboat.android.views.input.GestureConfig
import com.tugboat.android.views.navigation.NavEntry
import com.tugboat.android.views.navigation.NavigationObservation
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
import org.robolectric.Shadows.shadowOf

/**
 * `scene.inventory` through the Views adapter with `emitSceneInventory` on:
 * the visible route, the captured-frame trigger, and the structure skip.
 */
@RunWith(RobolectricTestRunner::class)
class SceneInventoryAdapterTest {
    private val sink = RecordingSink()
    private val frames = ManualFrames()
    private lateinit var adapter: ViewsAdapter
    private var walks = 0

    @Before
    fun setUp() {
        NavigationObservation.resetForTests()
        NavigationObservation.setFrameSchedulerForTests(frames)
        adapter = ViewsAdapter(
            application = context as Application,
            sink = sink,
            hostClock = FakeClock(monoUs = 50_000_000),
            frames = frames,
            gesture = GestureConfig(touchSlop = 8.0, panSlop = 16.0, scaleSlop = 16.0),
            emitSceneInventory = true,
            onInventoryWalk = { walks++ },
        ).apply { start() }
    }

    @After
    fun stop() = adapter.stop()

    @Test
    fun aFragmentInAContainerIsTheInventoryRouteAndHoldsTheTappedControl() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        val container = FragmentContainerView(activity).apply { id = CONTAINER_ID }
        activity.setContentView(
            LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                addView(Button(activity), LinearLayout.LayoutParams(400, 120))
                addView(container, LinearLayout.LayoutParams(720, 800))
            },
        )
        val fragment = HomeFragment()
        activity.supportFragmentManager.beginTransaction().replace(CONTAINER_ID, fragment, "home").commitNow()
        settle()

        adapter.onCapturedFrame(activity.window, "structure-1", hasRegionHosts = false)
        frames.runFrame()
        val inventory = inventoryInputs().single()
        assertEquals("home", inventory.getString("routeKey"))
        SceneInventoryFactContract.assertFact(inventory)

        tap(activity.window, fragment.button)
        frames.runFrame()
        val anchor = tapAnchor()
        assertEquals("home", anchor.getJSONObject("fingerprintParts").getString("routeKey"))
        assertTrue(anchor.getString("fingerprint") in fingerprints(inventory))
    }

    @Test
    fun aChildFragmentInsideAParentFragmentIsTheInventoryRoute() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        val parent = ParentFragment()
        activity.supportFragmentManager.beginTransaction().add(android.R.id.content, parent, "parent").commitNow()
        val child = HomeFragment()
        parent.childFragmentManager.beginTransaction().add(CHILD_CONTAINER_ID, child, "child").commitNow()
        settle()

        adapter.onCapturedFrame(activity.window, "structure-1", hasRegionHosts = false)
        frames.runFrame()
        val inventory = inventoryInputs().single()
        assertEquals("child", inventory.getString("routeKey"))

        tap(activity.window, child.button)
        frames.runFrame()
        val anchor = tapAnchor()
        assertEquals("child", anchor.getJSONObject("fingerprintParts").getString("routeKey"))
        assertTrue(anchor.getString("fingerprint") in fingerprints(inventory))
    }

    /** Split screen / picture-in-picture: the activity is paused but visible, so every fragment is paused too. */
    @Test
    fun aPausedButVisibleActivityKeepsTheVisibleFragmentAsTheInventoryRoute() {
        val controller = Robolectric.buildActivity(FragmentActivity::class.java).setup()
        val activity = controller.get()
        val parent = ParentFragment()
        activity.supportFragmentManager.beginTransaction().add(android.R.id.content, parent, "parent").commitNow()
        val child = HomeFragment()
        parent.childFragmentManager.beginTransaction().add(CHILD_CONTAINER_ID, child, "child").commitNow()
        settle()
        controller.pause()

        adapter.onCapturedFrame(activity.window, "structure-1", hasRegionHosts = false)
        frames.runFrame()
        assertEquals("child", inventoryInputs().single().getString("routeKey"))
    }

    /**
     * The `NavHostFragment` shape: a host fragment whose key is not the
     * destination's, holding the destination fragment (`trackNavigation`
     * reports each destination through `NavigationObservation.onNavDestination`).
     */
    @Test
    fun aNavHostShapedParentInventoriesTheCurrentDestination() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        val host = ParentFragment()
        activity.supportFragmentManager.beginTransaction().add(android.R.id.content, host).commitNow()
        NavigationObservation.onNavDestination(activity, NavEntry("entry-1", "home", 1), null)
        host.childFragmentManager.beginTransaction().replace(CHILD_CONTAINER_ID, HomeFragment()).commitNow()
        NavigationObservation.onNavDestination(activity, NavEntry("entry-2", "detail", 2), NavEntry("entry-1", "home", 1))
        host.childFragmentManager.beginTransaction().replace(CHILD_CONTAINER_ID, DetailFragment()).commitNow()
        settle()

        adapter.onCapturedFrame(activity.window, "structure-1", hasRegionHosts = false)
        frames.runFrame()

        val inventory = inventoryInputs().single()
        assertEquals("detail", inventory.getString("routeKey"))
        assertEquals(listOf("Button#button2"), elements(inventory).map { it.getString("canonicalPath") })
    }

    /** Two children in one container; the last drawn was resumed, then capped at `STARTED`. */
    @Test
    fun aPausedSiblingFragmentIsNotTheInventoryRoute() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        val parent = ParentFragment()
        activity.supportFragmentManager.beginTransaction().add(android.R.id.content, parent, "parent").commitNow()
        val shown = DetailFragment()
        val paused = HomeFragment()
        parent.childFragmentManager.beginTransaction()
            .add(CHILD_CONTAINER_ID, shown, "shown")
            .add(CHILD_CONTAINER_ID, paused, "paused")
            .commitNow()
        parent.childFragmentManager.beginTransaction().setMaxLifecycle(paused, Lifecycle.State.STARTED).commitNow()
        settle()
        assertFalse(paused.isResumed)

        adapter.onCapturedFrame(activity.window, "structure-1", hasRegionHosts = false)
        frames.runFrame()

        val inventory = inventoryInputs().single()
        assertEquals("shown", inventory.getString("routeKey"))
        assertEquals(listOf("Button#button2"), elements(inventory).map { it.getString("canonicalPath") })
    }

    @Test
    fun aParentWhoseChildrenAreAllPausedIsTheInventoryRoute() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        val parent = ParentFragment()
        activity.supportFragmentManager.beginTransaction().add(android.R.id.content, parent, "parent").commitNow()
        val child = HomeFragment()
        parent.childFragmentManager.beginTransaction().add(CHILD_CONTAINER_ID, child, "child").commitNow()
        parent.childFragmentManager.beginTransaction().setMaxLifecycle(child, Lifecycle.State.STARTED).commitNow()
        settle()

        adapter.onCapturedFrame(activity.window, "structure-1", hasRegionHosts = false)
        frames.runFrame()

        assertEquals("parent", inventoryInputs().single().getString("routeKey"))
    }

    /**
     * Tab 1 is visited, then the user returns to tab 0. With
     * `offscreenPageLimit = 1`, tab 1 stays attached (the last drawn page)
     * at `STARTED`; `FragmentStateAdapter` tags pages `f<itemId>`.
     */
    @Test
    fun aViewPagerInventoriesTheCurrentPageAfterReturningToIt() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        val tabs = PagerFragment()
        activity.supportFragmentManager.beginTransaction().add(android.R.id.content, tabs, "tabs").commitNow()
        settle()
        tabs.pager.setCurrentItem(1, false)
        settle()
        tabs.pager.setCurrentItem(0, false)
        settle()
        val pages = tabs.childFragmentManager.fragments.associateBy { it.tag }
        assertEquals(setOf("f0", "f1"), pages.keys)
        assertTrue(pages.getValue("f0").isResumed)
        assertFalse(pages.getValue("f1").isResumed)

        adapter.onCapturedFrame(activity.window, "structure-1", hasRegionHosts = false)
        frames.runFrame()

        val inventory = inventoryInputs().single()
        assertEquals("f0", inventory.getString("routeKey"))
        assertEquals(listOf("Button#button2"), elements(inventory).map { it.getString("canonicalPath") })
    }

    @Test
    fun aClickableFragmentRootIsAnElementWithTheEmptyPath() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        activity.supportFragmentManager.beginTransaction()
            .add(android.R.id.content, ClickableRootFragment(), "sheet").commitNow()
        settle()

        adapter.onCapturedFrame(activity.window, "structure-1", hasRegionHosts = false)
        frames.runFrame()

        val inventory = inventoryInputs().single()
        assertEquals("sheet", inventory.getString("routeKey"))
        val paths = elements(inventory).map { it.getString("canonicalPath") }
        assertTrue(paths.toString(), "" in paths)
        assertTrue(paths.toString(), "Button#0" in paths)
        SceneInventoryFactContract.assertFact(inventory)
    }

    @Test
    fun navigationAloneEmitsNoInventoryUntilTheRouteCaptureAnswers() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        val screen = FrameLayout(activity)
        activity.setContentView(
            LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                addView(Button(activity).apply { id = android.R.id.button1 }, LinearLayout.LayoutParams(400, 120))
                addView(screen, LinearLayout.LayoutParams(720, 600))
            },
        )
        screen.addView(Button(activity), FrameLayout.LayoutParams(300, 120))
        settle()
        adapter.onCapturedFrame(activity.window, "home-structure", hasRegionHosts = false)
        frames.runFrame()
        sink.batches.clear()

        // The destination changes and its screen is swapped in, not yet laid out.
        NavigationObservation.onNavDestination(activity, NavEntry("entry-2", "detail", 2), NavEntry("entry-1", "home", 1))
        screen.removeAllViews()
        screen.addView(Button(activity).apply { id = android.R.id.button2 }, FrameLayout.LayoutParams(300, 120))
        repeat(FRAMES) { frames.runFrame() }
        assertEquals(emptyList<JSONObject>(), inventoryInputs())
        shadowOf(Looper.getMainLooper()).idle()
        repeat(FRAMES) { frames.runFrame() }
        assertEquals(emptyList<JSONObject>(), inventoryInputs())

        // The route capture answers: the inventory holds the new screen.
        adapter.onCapturedFrame(activity.window, "detail-structure", hasRegionHosts = false)
        frames.runFrame()
        val inventory = inventoryInputs().single()
        assertEquals("detail", inventory.getString("routeKey"))
        assertTrue(elements(inventory).toString(), elements(inventory).any { it.getString("canonicalPath") == "Button#button2" })
    }

    @Test
    fun anUnchangedStructureNeitherWalksNorEmits() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        activity.setContentView(Button(activity))
        settle()
        assertFalse(adapter.masks(activity.window).hasRegionHosts)

        adapter.onCapturedFrame(activity.window, "structure-1", hasRegionHosts = false)
        adapter.onCapturedFrame(activity.window, "structure-1", hasRegionHosts = false)
        frames.runFrame()

        assertEquals(1, walks)
        assertEquals(1, inventoryInputs().size)
    }

    @Test
    fun anEmptyInventoryDoesNotStoreTheSignature() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        val screen = FrameLayout(activity)
        activity.setContentView(screen)
        settle()
        adapter.onCapturedFrame(activity.window, "structure-1", hasRegionHosts = false)
        frames.runFrame()
        assertEquals(emptyList<JSONObject>(), inventoryInputs())

        screen.addView(Button(activity), FrameLayout.LayoutParams(300, 120))
        settle()
        adapter.onCapturedFrame(activity.window, "structure-1", hasRegionHosts = false)
        frames.runFrame()

        assertEquals(2, walks)
        assertEquals(1, inventoryInputs().size)
    }

    @Test
    fun aCaptureCompletionReachesTheMainThreadOnlyWhenInventoryIsOn() {
        val off = ViewsAdapter(application = context as Application, sink = sink, frames = frames).apply { start() }
        var posted = 0
        off.onCaptureCompleted("structure-1", hasRegionHosts = false, mainThread = { posted++; true }) { null }
        off.stop()
        assertEquals(0, posted)

        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        activity.setContentView(Button(activity))
        settle()
        adapter.onCaptureCompleted("structure-1", hasRegionHosts = false, mainThread = { it.run(); posted++; true }) { activity.window }
        frames.runFrame()

        assertEquals(1, posted)
        assertEquals(1, inventoryInputs().size)
    }

    @Test
    fun aSecureWindowIsNeverWalked() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        activity.setContentView(Button(activity))
        activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        settle()

        adapter.onCapturedFrame(activity.window, "structure-1", hasRegionHosts = false)
        frames.runFrame()

        assertEquals(0, walks)
        assertEquals(emptyList<JSONObject>(), inventoryInputs())
    }

    private fun settle() {
        shadowOf(Looper.getMainLooper()).idle()
        repeat(FRAMES) { frames.runFrame() }
        sink.batches.clear()
    }

    private fun inventoryInputs(): List<JSONObject> =
        sink.batches.flatten().filter { it.type == "scene.inventory" }.map { JSONObject(it.inputJson) }

    private fun tapAnchor(): JSONObject =
        sink.batches.flatten().filter { it.type == "input.pointer" }
            .map { JSONObject(it.inputJson) }
            .last { it.has("tap") }
            .getJSONObject("tap").getJSONObject("anchor")

    private fun elements(inventory: JSONObject): List<JSONObject> {
        val array = inventory.getJSONArray("elements")
        return (0 until array.length()).map { array.getJSONObject(it) }
    }

    private fun fingerprints(inventory: JSONObject): List<String> = elements(inventory).map { it.getString("fingerprint") }

    private fun tap(window: Window, view: View) {
        val location = IntArray(2)
        view.getLocationInWindow(location)
        val x = location[0] + view.width / 2f
        val y = location[1] + view.height / 2f
        window.callback.dispatchTouchEvent(MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, x, y, 0))
        window.callback.dispatchTouchEvent(MotionEvent.obtain(0, 1, MotionEvent.ACTION_UP, x, y, 0))
    }

    class HomeFragment : Fragment() {
        lateinit var button: Button

        override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View {
            button = Button(inflater.context)
            return FrameLayout(inflater.context).apply { addView(button, FrameLayout.LayoutParams(300, 200)) }
        }
    }

    /** A parent fragment with its own button and a container for child fragments. */
    class ParentFragment : Fragment() {
        override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View =
            LinearLayout(inflater.context).apply {
                orientation = LinearLayout.VERTICAL
                addView(Button(inflater.context), LinearLayout.LayoutParams(300, 120))
                addView(FragmentContainerView(inflater.context).apply { id = CHILD_CONTAINER_ID }, LinearLayout.LayoutParams(720, 600))
            }
    }

    class DetailFragment : Fragment() {
        override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View =
            FrameLayout(inflater.context).apply {
                addView(Button(inflater.context).apply { id = android.R.id.button2 }, FrameLayout.LayoutParams(300, 120))
            }
    }

    /** A two-page `ViewPager2`: page 0 is a [DetailFragment], page 1 a [HomeFragment]. */
    class PagerFragment : Fragment() {
        lateinit var pager: ViewPager2

        override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View {
            pager = ViewPager2(inflater.context).apply {
                offscreenPageLimit = 1
                adapter = object : FragmentStateAdapter(this@PagerFragment) {
                    override fun getItemCount() = 2

                    override fun createFragment(position: Int): Fragment = if (position == 0) DetailFragment() else HomeFragment()
                }
            }
            return FrameLayout(inflater.context).apply { addView(pager, FrameLayout.LayoutParams(720, 600)) }
        }
    }

    /** A full-screen fragment whose root is clickable, to stop clicks reaching what is below. */
    class ClickableRootFragment : Fragment() {
        override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View =
            FrameLayout(inflater.context).apply {
                isClickable = true
                addView(Button(inflater.context), FrameLayout.LayoutParams(300, 200))
            }
    }

    private companion object {
        val CONTAINER_ID = View.generateViewId()
        val CHILD_CONTAINER_ID = View.generateViewId()

        /** Frames to run when settling: a focused view can keep asking for frames. */
        const val FRAMES = 4
    }
}
