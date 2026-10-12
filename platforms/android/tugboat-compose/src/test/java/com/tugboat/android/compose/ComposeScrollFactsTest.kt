package com.tugboat.android.compose

import android.os.SystemClock
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
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import com.tugboat.android.views.facts.FactTypes
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

/** Scroll facts by per-frame diff of semantics scroll ranges (native SDK note 5). */
@RunWith(RobolectricTestRunner::class)
class ComposeScrollFactsTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(RegionRule()).around(compose)

    private val lazy = LazyListState()
    private val column = ScrollState(0)
    private val clock = ManualClock()
    private val facts = RecordingFacts()
    private lateinit var tracker: RegionScrollTracker

    @Before
    fun setUp() {
        compose.setContent {
            Column {
                LazyColumn(Modifier.height(200.dp), state = lazy) {
                    items(100) { Text("Row $it", Modifier.height(40.dp)) }
                }
                Column(Modifier.height(200.dp).verticalScroll(column)) {
                    repeat(10) { Box(Modifier.fillMaxWidth().height(100.dp)) }
                }
            }
        }
        compose.waitForIdle()
        val resolver = anchorResolver(compose.activity)
        tracker = RegionScrollTracker(compose.activity.decor, factClock(clock), resolver.regions::anchor, facts::emit, requestFrame = {})
    }

    private fun touch(action: Int) {
        val now = SystemClock.uptimeMillis()
        val event = MotionEvent.obtain(now, now, action, 10f, 10f, 0)
        tracker.onTouch(event)
        event.recycle()
    }

    private fun scroll(block: suspend () -> Unit) {
        compose.runOnIdle { runBlocking { block() } }
        compose.waitForIdle()
    }

    private fun scrolls(): List<JSONObject> = facts.inputs(FactTypes.SCROLL)

    @Test
    fun aLazyColumnScrollSendsStartUpdateEndWithItsAnchor() {
        touch(MotionEvent.ACTION_DOWN)
        scroll { lazy.scrollBy(300f) }
        clock.advanceMs(16)
        tracker.onFrame()
        touch(MotionEvent.ACTION_UP)
        clock.advanceMs(200)
        tracker.onFrame()

        val phases = scrolls().map { it.getString("phase") }
        assertEquals(listOf("start", "update", "end"), phases)
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
        assertEquals(scrolls().map { it.getString("scrollableId") }.toSet().size, 1)
    }

    @Test
    fun aScrollModifierReportsPixelOffsetsInDpAndItsExtent() {
        touch(MotionEvent.ACTION_DOWN)
        scroll { column.scrollBy(150f) }
        tracker.onFrame()
        touch(MotionEvent.ACTION_UP)
        clock.advanceMs(200)
        tracker.onFrame()

        val update = scrolls().first { it.getString("phase") == "update" }
        val density = compose.activity.resources.displayMetrics.density.toDouble()
        assertEquals(150.0 / density, update.getDouble("offset"), 1e-6)
        assertEquals(column.maxValue / density, update.getDouble("maxScrollExtent"), 1e-6)
        assertEquals("Compose#0/Scrollable#1", scrolls().first().getJSONObject("anchor").getString("canonicalPath"))
    }

    @Test
    fun nothingIsSentWithoutMovementOrOutsideAGesture() {
        touch(MotionEvent.ACTION_DOWN)
        tracker.onFrame()
        touch(MotionEvent.ACTION_UP)
        clock.advanceMs(2_000)
        scroll { lazy.scrollBy(300f) }
        tracker.onFrame()
        assertTrue(scrolls().isEmpty())
    }
}
