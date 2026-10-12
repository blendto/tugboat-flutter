package com.tugboat.android.views

import android.app.Activity
import android.graphics.RectF
import android.view.MotionEvent
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.compose.ui.platform.ComposeView
import com.tugboat.android.host.FakeClock
import com.tugboat.android.toolkit.RegionFocus
import com.tugboat.android.toolkit.RegionMasks
import com.tugboat.android.toolkit.RegionScrollable
import com.tugboat.android.views.input.FocusFactProducer
import com.tugboat.android.views.mask.MaskRect
import com.tugboat.android.views.mask.WindowMasks
import com.tugboat.android.views.scroll.RegionScrollTracker
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

/** Masks, scroll, focus, and navigation through the toolkit-region seam (generic: a fake region). */
@RunWith(RobolectricTestRunner::class)
class ToolkitRegionFactsTest {
    @get:Rule
    val regionRule = FakeRegionRule()
    private val region get() = regionRule.region

    private val host = FakeHostView(context)
    private val root = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        addView(TextView(context), LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 200))
        addView(host, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 600))
    }

    @Test
    fun regionMaskRectsAreMappedOutOfTheHost() {
        region.masks = RegionMasks(listOf(RectF(0f, 0f, 500f, 300f)), wholeFrame = false)
        layOut(root, 1000, 1000)
        val result = WindowMasks.compute(root)
        assertFalse(result.failClosed)
        assertEquals(listOf(MaskRect(0.0, 0.0, 1.0, 0.2), MaskRect(0.0, 0.2, 0.5, 0.3)), result.rects)
    }

    @Test
    fun aRegionAskingForTheWholeFrameOrThrowingMasksTheWholeFrame() {
        layOut(root, 1000, 1000)
        region.masks = RegionMasks.WHOLE_FRAME
        assertEquals(listOf(MaskRect.FULL_FRAME), WindowMasks.compute(root).rects)
        region.throwing = true
        assertTrue(WindowMasks.compute(root).failClosed)
    }

    @Test
    fun aComposeViewWhoseChildIsARegionHostIsNotFailClosed() {
        val compose = ComposeView(context).apply { addView(FakeHostView(context), FrameLayout.LayoutParams(1000, 300)) }
        val screen = FrameLayout(context).apply { addView(compose, FrameLayout.LayoutParams(1000, 300)) }
        layOut(screen, 1000, 1000)
        assertEquals(null, WindowMasks.sourceOf(compose))
        assertEquals(emptyList<MaskRect>(), WindowMasks.compute(screen).rects)
    }

    @Test
    fun regionScrollablesAreDiffedPerFrameDuringAGesture() {
        val clock = FakeClock()
        val recorded = RecordingFacts()
        layOut(root, 1000, 1000)
        val tracker = RegionScrollTracker(root, factClock(clock), { _, _ -> null }, recorded::emit, requestFrame = {})
        region.scrollables = listOf(RegionScrollable(7, vertical = true, offsetPx = 0f, maxExtentPx = 900f, target = { null }))
        tracker.onTouch(MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, 10f, 10f, 0))
        region.scrollables = listOf(RegionScrollable(7, vertical = true, offsetPx = 120f, maxExtentPx = 900f, target = { null }))
        clock.monoUs += 16_000
        tracker.onFrame()
        tracker.onTouch(MotionEvent.obtain(0, 20, MotionEvent.ACTION_UP, 10f, 10f, 0))
        clock.monoUs += 200_000
        tracker.onFrame()
        val scrolls = recorded.inputs("scroll")
        assertEquals(listOf("start", "update", "end"), scrolls.map { it.getString("phase") })
        assertEquals(listOf(0.0, 120.0, 120.0), scrolls.map { it.getDouble("offset") })
        assertTrue(scrolls[0].getString("scrollableId").startsWith("compose-scroll-"))
        assertEquals(900.0, scrolls[1].getDouble("maxScrollExtent"), 0.0)
    }

    @Test
    fun regionFocusIsReadWhenTheHostHasViewFocusAndRecheckedAfterInput() {
        val recorded = RecordingFacts()
        val focus = FocusFactProducer(factClock(), recorded::emit)
        region.focus = RegionFocus.Other
        focus.onGlobalFocusChanged(null, host)
        region.focus = RegionFocus.TextInput
        assertFalse(focus.onFrame(host)) // no input since: no recheck
        focus.onInput()
        focus.onFrame(host)
        assertEquals(listOf("other", "text_input"), recorded.inputs("focus").map { it.getString("kind") })
    }

    @Test
    fun theTrackNavigationHookReachesEveryRegion() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val adapter = ViewsAdapter(activity.application, RecordingSink(), frames = ManualFrames())
        adapter.onDestinationChanged(activity, "profile/{id}", 0)
        assertEquals(listOf(activity to "profile/{id}"), region.destinations)
    }
}
