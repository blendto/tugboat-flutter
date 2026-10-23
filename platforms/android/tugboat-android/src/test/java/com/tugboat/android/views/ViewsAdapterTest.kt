package com.tugboat.android.views

import android.app.Application
import android.os.Bundle
import android.os.Looper
import android.view.KeyEvent
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import com.tugboat.android.host.FakeClock
import com.tugboat.android.views.identity.Confidence
import com.tugboat.android.views.identity.IdentityHash
import com.tugboat.android.views.input.GestureConfig
import org.json.JSONObject
import com.tugboat.android.views.navigation.NavigationObservation
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

/** End to end through a real activity window: facts leave once per frame, each with its own time. */
@RunWith(RobolectricTestRunner::class)
class ViewsAdapterTest {
    private val sink = RecordingSink()
    private val frames = ManualFrames()
    private val clock = FakeClock(monoUs = 50_000_000)
    private lateinit var adapter: ViewsAdapter

    @Before
    fun setUp() {
        NavigationObservation.resetForTests()
        NavigationObservation.setFrameSchedulerForTests(frames)
        sink.batches.clear()
        adapter = ViewsAdapter(
            application = context as Application,
            sink = sink,
            hostClock = clock,
            frames = frames,
            gesture = GestureConfig(touchSlop = 8.0, panSlop = 16.0, scaleSlop = 16.0),
        ).apply { start() }
    }

    @After
    fun stop() = adapter.stop()

    @Test
    fun sceneInventoryBeforeTapIncludesTheTappedFingerprint() {
        val inventoryAdapter = ViewsAdapter(
            application = context as Application,
            sink = sink,
            hostClock = clock,
            frames = frames,
            gesture = GestureConfig(touchSlop = 8.0, panSlop = 16.0, scaleSlop = 16.0),
            emitSceneInventory = true,
        ).apply { start() }
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        val button = Button(activity).apply { id = android.R.id.button1 }
        activity.setContentView(LinearLayout(activity).apply { addView(button, LinearLayout.LayoutParams(400, 200)) })
        shadowOf(Looper.getMainLooper()).idle()
        drain()

        inventoryAdapter.onCapturedFrame(activity.window, "structure-1")
        frames.runFrame()
        val inventoryFact = sink.batches.single().single()
        assertEquals("scene.inventory", inventoryFact.type)

        tap(activity.window, button)
        frames.runFrame()
        val tapAnchor = JSONObject(sink.batches.last()[1].inputJson).getJSONObject("tap").getJSONObject("anchor")
        val fingerprint = tapAnchor.getString("fingerprint")
        val elements = JSONObject(inventoryFact.inputJson).getJSONArray("elements")
        val fingerprints = (0 until elements.length()).map { elements.getJSONObject(it).getString("fingerprint") }
        assertTrue(fingerprint in fingerprints)
        inventoryAdapter.stop()
    }

    @Test
    fun aTapOnAnActivityButtonIsPostedInOneBatchWithItsAnchor() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        val button = Button(activity).apply { id = android.R.id.button1 }
        activity.setContentView(LinearLayout(activity).apply { addView(button, LinearLayout.LayoutParams(400, 200)) })
        shadowOf(Looper.getMainLooper()).idle()
        drain()

        val (x, y) = centerInWindow(button)
        val window = activity.window
        window.callback.dispatchTouchEvent(MotionEvent.obtain(0, 1_000, MotionEvent.ACTION_DOWN, x, y, 0))
        window.callback.dispatchTouchEvent(MotionEvent.obtain(0, 1_050, MotionEvent.ACTION_UP, x + 2f, y + 1f, 0))
        assertTrue("nothing is posted before the frame", sink.batches.isEmpty())

        frames.runFrame()
        val batch = sink.batches.single()
        assertEquals(listOf("input.pointer", "input.pointer"), batch.map { it.type })
        assertEquals(listOf(1_000_000L, 1_050_000L), batch.map { it.at!!.monoUs })
        val up = JSONObject(batch[1].inputJson)
        val anchor = up.getJSONObject("tap").getJSONObject("anchor")
        val routeKey = FragmentActivity::class.java.name
        val path = anchor.getString("canonicalPath")
        assertEquals("Button#button1", path)
        assertEquals(IdentityHash.fingerprint(mapOf("routeKey" to routeKey, "path" to path)), anchor.getString("fingerprint"))
        assertEquals("button1", anchor.getJSONObject("fingerprintParts").getString("tag"))
        assertEquals(Confidence.High.wire, anchor.getString("fingerprintConfidence"))
        assertEquals("view", anchor.getString("toolkit"))
    }

    @Test
    fun aTapInsideAFragmentUsesTheFragmentRouteAndRoot() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        val fragment = ButtonFragment()
        activity.supportFragmentManager.beginTransaction().add(android.R.id.content, fragment, "checkout").commitNow()
        shadowOf(Looper.getMainLooper()).idle()
        drain()

        tap(activity.window, (fragment.requireView() as ViewGroup).getChildAt(0))
        frames.runFrame()

        val anchor = JSONObject(sink.batches.single()[1].inputJson).getJSONObject("tap").getJSONObject("anchor")
        assertEquals("checkout", anchor.getJSONObject("fingerprintParts").getString("routeKey"))
        assertEquals("Button#0", anchor.getString("canonicalPath"))
    }

    @Test
    fun aNavigationDestinationIsTheRouteKeyForActivityLevelViews() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        val button = Button(activity)
        activity.setContentView(button)
        shadowOf(Looper.getMainLooper()).idle()
        drain()
        NavigationObservation.onDestinationChanged(activity, "checkout/{id}?step={step}", 0)

        tap(activity.window, button)
        frames.runFrame()

        val anchor = JSONObject(sink.batches.single()[1].inputJson).getJSONObject("tap").getJSONObject("anchor")
        // Arguments are stripped, so Views and Compose share the route key.
        assertEquals("checkout", anchor.getJSONObject("fingerprintParts").getString("routeKey"))
    }

    @Test
    fun focusAndKeysFromTheWindowAreFacts() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        val field = EditText(activity)
        activity.setContentView(FrameLayout(activity).apply { addView(field) })
        shadowOf(Looper.getMainLooper()).idle()
        drain()

        field.requestFocus()
        shadowOf(Looper.getMainLooper()).idle()
        activity.window.callback.dispatchKeyEvent(KeyEvent(0, 10, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_VOLUME_UP, 0))
        frames.runFrame()

        val types = sink.batches.flatten().map { it.type }
        assertTrue(types.toString(), types.containsAll(listOf("focus", "systemInput")))
    }

    @Test
    fun stopDetachesAndRestoresTheWindowCallback() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        drain()
        adapter.stop()
        assertTrue(activity.window.callback === activity)
        activity.window.callback.dispatchTouchEvent(MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, 1f, 1f, 0))
        frames.runFrame()
        assertTrue(sink.batches.isEmpty())
    }

    @Test
    fun nothingIsEmittedAfterStop() {
        val navigating = ViewsAdapter(context as Application, sink, clock, frames, postNavigationFacts = true)
        adapter.stop()
        navigating.start()
        val controller = Robolectric.buildActivity(FragmentActivity::class.java).setup()
        val activity = controller.get()
        activity.setContentView(Button(activity))
        shadowOf(Looper.getMainLooper()).idle()
        drain()

        navigating.stop()
        activity.supportFragmentManager.beginTransaction().add(android.R.id.content, ButtonFragment(), "late").commitNow()
        activity.window.callback.dispatchTouchEvent(MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, 5f, 5f, 0))
        activity.window.callback.dispatchKeyEvent(KeyEvent(0, 1, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_BACK, 0))
        controller.pause().stop().destroy()
        while (frames.hasPending) frames.runFrame()

        assertTrue(sink.batches.toString(), sink.batches.isEmpty())
    }

    private fun centerInWindow(view: View): Pair<Float, Float> {
        val location = IntArray(2)
        view.getLocationInWindow(location)
        return location[0] + view.width / 2f to location[1] + view.height / 2f
    }

    private fun tap(window: Window, view: View) {
        val (x, y) = centerInWindow(view)
        window.callback.dispatchTouchEvent(MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, x, y, 0))
        window.callback.dispatchTouchEvent(MotionEvent.obtain(0, 1, MotionEvent.ACTION_UP, x, y, 0))
    }

    private fun drain() {
        while (frames.hasPending) frames.runFrame()
        sink.batches.clear()
    }

    class ButtonFragment : Fragment() {
        override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View =
            FrameLayout(inflater.context).apply { addView(Button(inflater.context), FrameLayout.LayoutParams(300, 300)) }
    }
}
