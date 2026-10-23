package com.tugboat.android.views.compose

import android.app.Application
import android.os.Bundle
import android.os.Looper
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.ui.platform.ComposeView
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import com.tugboat.android.host.FakeClock
import com.tugboat.android.views.ManualFrames
import com.tugboat.android.views.RecordingSink
import com.tugboat.android.views.ViewsAdapter
import com.tugboat.android.views.context
import com.tugboat.android.views.input.GestureConfig
import com.tugboat.android.views.inventory.SceneInventoryFactContract
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TestRule
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.time.Duration

/**
 * The Compose-in-fragment pattern (`onCreateView` returns a `ComposeView`)
 * through the Views adapter: the tapped Compose button's fingerprint is its
 * inventory element's, under the fragment's route.
 */
@RunWith(RobolectricTestRunner::class)
class ComposeFragmentSceneInventoryTest {
    @get:Rule
    val install: TestRule = ComposeInstallRule()

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
    fun aTappedComposeButtonInAFragmentIsInTheInventory() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        activity.supportFragmentManager.beginTransaction()
            .add(android.R.id.content, PayFragment(), "pay").commitNow()
        settle()
        val host = composeHost(activity.window.decorView)
        if (host == null) return fail("expected a Compose host")

        adapter.onCapturedFrame(activity.window, "structure-1")
        frames.runFrame()
        val inventory = sink.batches.flatten().single { it.type == "scene.inventory" }.let { JSONObject(it.inputJson) }
        sink.batches.clear()
        assertEquals("pay", inventory.getString("routeKey"))
        SceneInventoryFactContract.assertFact(inventory)
        assertNoText(inventory, "Pay")

        val location = IntArray(2)
        host.getLocationInWindow(location)
        val x = location[0] + 20f
        val y = location[1] + 20f
        activity.window.callback.dispatchTouchEvent(MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, x, y, 0))
        activity.window.callback.dispatchTouchEvent(MotionEvent.obtain(0, 1, MotionEvent.ACTION_UP, x, y, 0))
        frames.runFrame()
        val anchor = sink.batches.flatten().filter { it.type == "input.pointer" }
            .map { JSONObject(it.inputJson) }
            .last { it.has("tap") }
            .getJSONObject("tap").getJSONObject("anchor")
        assertEquals("compose", anchor.getString("toolkit"))

        val elements = inventory.getJSONArray("elements")
        val paths = (0 until elements.length()).associate {
            elements.getJSONObject(it).getString("fingerprint") to elements.getJSONObject(it).getString("canonicalPath")
        }
        assertTrue(paths.toString(), anchor.getString("fingerprint") in paths)
        assertEquals(anchor.getString("canonicalPath"), paths[anchor.getString("fingerprint")])
        assertTrue(paths.toString(), paths.values.none { it.startsWith("/") })
    }

    private fun settle() {
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(100))
        while (frames.hasPending) frames.runFrame()
        sink.batches.clear()
    }

    class PayFragment : Fragment() {
        override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View =
            ComposeView(inflater.context).apply {
                setContent {
                    Column {
                        Button(onClick = {}) { Text("Pay") }
                    }
                }
            }
    }
}
