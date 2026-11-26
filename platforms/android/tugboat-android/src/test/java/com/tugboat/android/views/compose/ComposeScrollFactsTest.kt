package com.tugboat.android.views.compose

import android.view.MotionEvent
import androidx.activity.ComponentActivity
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import com.tugboat.android.host.FakeClock
import com.tugboat.android.views.RecordingFacts
import com.tugboat.android.views.facts.FactTypes
import com.tugboat.android.views.factClock
import com.tugboat.android.views.scroll.RegionScrollTracker
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Scroll facts from the scrollables under the touch, read per frame (native SDK note 5). */
@RunWith(RobolectricTestRunner::class)
class ComposeScrollFactsTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(ComposeInstallRule()).around(compose)

    private val lazy = LazyListState()
    private val column = ScrollState(0)
    private val clock = FakeClock()
    private val facts = RecordingFacts()
    private lateinit var tracker: RegionScrollTracker

    @Before
    fun setUp() {
        compose.setContent {
            Column {
                LazyColumn(Modifier.height(150.dp).testTag("lazy"), state = lazy) {
                    items(100) { Text("Row $it", Modifier.height(40.dp)) }
                }
                Column(Modifier.height(150.dp).verticalScroll(column).testTag("column")) {
                    repeat(10) { Box(Modifier.fillMaxWidth().height(100.dp)) }
                }
            }
        }
        compose.waitForIdle()
        val resolver = anchorResolver(compose.activity)
        tracker = RegionScrollTracker(compose.activity.decor, factClock(clock), resolver.regions::anchor, facts::emit, requestFrame = {})
    }

    private fun touch(action: Int, tag: String) {
        val center = compose.onNodeWithTag(tag).node.boundsInWindow.center
        val event = MotionEvent.obtain(0, 0, action, center.x, center.y, 0)
        tracker.onTouch(event)
        event.recycle()
    }

    private fun scroll(block: suspend () -> Unit) {
        compose.runOnIdle { runBlocking { block() } }
        compose.waitForIdle()
    }

    private fun advanceMs(ms: Long) {
        clock.monoUs += ms * 1_000
    }

    private fun scrolls(): List<JSONObject> = facts.inputs(FactTypes.SCROLL)

    @Test
    fun aLazyColumnScrollSendsStartUpdateEndWithItsAnchor() {
        touch(MotionEvent.ACTION_DOWN, "lazy")
        scroll { lazy.scrollBy(300f) }
        advanceMs(16)
        tracker.onFrame()
        touch(MotionEvent.ACTION_UP, "lazy")
        advanceMs(200)
        tracker.onFrame()

        assertEquals(listOf("start", "update", "end"), scrolls().map { it.getString("phase") })
        val start = scrolls().first()
        assertTrue(start.getString("scrollableId").startsWith("compose-scroll-"))
        assertEquals(0.0, start.getDouble("offset"), 0.0)
        val anchor = start.getJSONObject("anchor")
        assertEquals("compose", anchor.getString("toolkit"))
        assertEquals("Compose#0/Scrollable#0", anchor.getString("canonicalPath"))
        assertEquals("scrollable", anchor.getString("role"))
        val update = scrolls()[1]
        assertTrue(update.getDouble("offset") > 0.0)
        assertEquals("vertical", update.getString("axis"))
        // Lazy extents are Compose placeholders, so none is sent.
        assertFalse(update.has("maxScrollExtent"))
    }

    @Test
    fun aScrollModifierReportsPixelOffsetsInDpAndItsExtent() {
        touch(MotionEvent.ACTION_DOWN, "column")
        scroll { column.scrollBy(150f) }
        tracker.onFrame()
        touch(MotionEvent.ACTION_UP, "column")
        advanceMs(200)
        tracker.onFrame()

        val update = scrolls().first { it.getString("phase") == "update" }
        val density = compose.activity.resources.displayMetrics.density.toDouble()
        assertEquals(150.0 / density, update.getDouble("offset"), 1e-6)
        assertEquals(column.maxValue / density, update.getDouble("maxScrollExtent"), 1e-6)
        assertEquals("Compose#0/Scrollable#1", scrolls().first().getJSONObject("anchor").getString("canonicalPath"))
    }

    @Test
    fun onlyScrollablesUnderTheTouchAreRead() {
        touch(MotionEvent.ACTION_DOWN, "column")
        scroll { lazy.scrollBy(300f) }
        tracker.onFrame()
        assertTrue(scrolls().isEmpty())
    }

    @Test
    fun nothingIsSentWithoutMovementOrOutsideAGesture() {
        touch(MotionEvent.ACTION_DOWN, "lazy")
        tracker.onFrame()
        touch(MotionEvent.ACTION_UP, "lazy")
        advanceMs(2_000)
        scroll { lazy.scrollBy(300f) }
        tracker.onFrame()
        assertTrue(scrolls().isEmpty())
    }
}
