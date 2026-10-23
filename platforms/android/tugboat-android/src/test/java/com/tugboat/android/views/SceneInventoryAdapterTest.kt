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
import com.tugboat.android.host.FakeClock
import com.tugboat.android.views.inventory.SceneInventoryFactContract
import com.tugboat.android.views.input.GestureConfig
import com.tugboat.android.views.navigation.NavEntry
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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
    private val adapter = ViewsAdapter(
        application = context as Application,
        sink = sink,
        hostClock = FakeClock(monoUs = 50_000_000),
        frames = frames,
        gesture = GestureConfig(touchSlop = 8.0, panSlop = 16.0, scaleSlop = 16.0),
        emitSceneInventory = true,
    ).apply { start() }

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

        adapter.onCapturedFrame(activity.window, "structure-1")
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
    fun aClickableFragmentRootIsAnElementWithTheEmptyPath() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        activity.supportFragmentManager.beginTransaction()
            .add(android.R.id.content, ClickableRootFragment(), "sheet").commitNow()
        settle()

        adapter.onCapturedFrame(activity.window, "structure-1")
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
        activity.setContentView(Button(activity).apply { id = android.R.id.button1 })
        settle()
        adapter.onCapturedFrame(activity.window, "home-structure")
        frames.runFrame()
        sink.batches.clear()

        adapter.onNavDestination(activity, NavEntry("entry-2", "detail", 2), NavEntry("entry-1", "home", 1))
        val detail = Button(activity).apply { id = android.R.id.button2 }
        activity.setContentView(detail)
        repeat(FRAMES) { frames.runFrame() }
        shadowOf(Looper.getMainLooper()).idle()
        repeat(FRAMES) { frames.runFrame() }
        assertEquals(emptyList<JSONObject>(), inventoryInputs())

        adapter.onCapturedFrame(activity.window, "detail-structure")
        frames.runFrame()
        val inventory = inventoryInputs().single()
        assertEquals("detail", inventory.getString("routeKey"))
        assertEquals(listOf("Button#button2"), elements(inventory).map { it.getString("canonicalPath") })
    }

    @Test
    fun anUnchangedStructureNeitherWalksNorEmits() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        activity.setContentView(Button(activity))
        settle()

        adapter.onCapturedFrame(activity.window, "structure-1")
        adapter.onCapturedFrame(activity.window, "structure-1")
        frames.runFrame()

        assertEquals(1, adapter.sceneInventoryWalks)
        assertEquals(1, inventoryInputs().size)
    }

    @Test
    fun anEmptyInventoryDoesNotStoreTheSignature() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        val screen = FrameLayout(activity)
        activity.setContentView(screen)
        settle()
        adapter.onCapturedFrame(activity.window, "structure-1")
        frames.runFrame()
        assertEquals(emptyList<JSONObject>(), inventoryInputs())

        screen.addView(Button(activity), FrameLayout.LayoutParams(300, 120))
        settle()
        adapter.onCapturedFrame(activity.window, "structure-1")
        frames.runFrame()

        assertEquals(2, adapter.sceneInventoryWalks)
        assertEquals(1, inventoryInputs().size)
    }

    @Test
    fun aSecureWindowIsNeverWalked() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        activity.setContentView(Button(activity))
        activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        settle()

        adapter.onCapturedFrame(activity.window, "structure-1")
        frames.runFrame()

        assertEquals(0, adapter.sceneInventoryWalks)
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

        /** Frames to run when settling: a focused view can keep asking for frames. */
        const val FRAMES = 4
    }
}
