package com.tugboat.android.compose

import android.os.SystemClock
import android.view.MotionEvent
import androidx.activity.ComponentActivity
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import com.tugboat.android.host.EngineMessage
import com.tugboat.android.toolkit.ToolkitRegions
import com.tugboat.android.views.ViewsAdapter
import com.tugboat.android.views.facts.FactSink
import com.tugboat.android.views.facts.FactTypes
import com.tugboat.android.views.facts.FrameScheduler
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * `TugboatCompose.install()` plus the Views adapter, end to end: a touch
 * through the activity's window callback becomes an `input.pointer` fact
 * whose tap anchor is Compose's; after `stop()` nothing is emitted.
 */
@RunWith(RobolectricTestRunner::class)
class ComposeAdapterEndToEndTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val batches = ArrayList<List<EngineMessage>>()
    private val frames = ArrayList<() -> Unit>()
    private lateinit var adapter: ViewsAdapter

    @Before
    fun setUp() {
        TugboatCompose.install()
        TugboatCompose.install()
        compose.setContent { Button(onClick = {}) { Text("Continue") } }
        adapter = ViewsAdapter(compose.activity.application, FactSink { batches += it }, frames = FrameScheduler { frames += it })
        compose.runOnIdle {
            adapter.start()
            adapter.onActivityCreated(compose.activity, null)
        }
    }

    @After
    fun tearDown() {
        ToolkitRegions.unregister(ComposeRegion.Default)
    }

    private fun tapContinue() {
        val center = compose.onNodeWithText("Continue").node.boundsInWindow.center
        compose.runOnIdle {
            val now = SystemClock.uptimeMillis()
            for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                val event = MotionEvent.obtain(now, now, action, center.x, center.y, 0)
                compose.activity.window.callback.dispatchTouchEvent(event)
                event.recycle()
            }
        }
    }

    private fun runFrames() {
        compose.runOnIdle {
            repeat(3) {
                val pending = frames.toList()
                frames.clear()
                pending.forEach { it() }
            }
        }
    }

    private fun pointerFacts(): List<JSONObject> =
        batches.flatten().filter { it.type == FactTypes.POINTER }.map { JSONObject(it.inputJson) }

    @Test
    fun installIsIdempotent() {
        assertEquals(1, ToolkitRegions.all.count { it === ComposeRegion.Default })
    }

    @Test
    fun aComposeTapTravelsAsAComposeAnchor() {
        tapContinue()
        runFrames()
        val up = pointerFacts().single { it.getString("phase") == "up" }
        val anchor = up.getJSONObject("tap").getJSONObject("anchor")
        assertEquals("compose", anchor.getString("toolkit"))
        assertEquals("Compose#0/Button#0", anchor.getString("canonicalPath"))
    }

    @Test
    fun nothingIsEmittedAfterStop() {
        compose.runOnIdle { adapter.stop() }
        val before = batches.size
        tapContinue()
        runFrames()
        assertEquals(before, batches.size)
        assertTrue(pointerFacts().isEmpty())
    }
}
