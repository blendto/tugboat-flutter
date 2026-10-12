package com.tugboat.android.views

import android.graphics.RectF
import android.view.MotionEvent
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import com.tugboat.android.host.FakeClock
import com.tugboat.android.toolkit.MaskCoverageReason
import com.tugboat.android.toolkit.RegionFocus
import com.tugboat.android.toolkit.RegionMasks
import com.tugboat.android.toolkit.RegionScrollable
import com.tugboat.android.views.input.FocusFactProducer
import com.tugboat.android.views.mask.MaskMode
import com.tugboat.android.views.mask.MaskRect
import com.tugboat.android.views.mask.WindowMasks
import com.tugboat.android.views.scroll.RegionScrollTracker
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.Executors

/** Masks, coverage, scroll, and focus through the toolkit-region seam (generic: a fake region). */
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
    fun preciseRegionRectsAreMappedOutOfTheHost() {
        region.masks = RegionMasks.Rects(listOf(RectF(0f, 0f, 500f, 300f)), setOf(MaskCoverageReason.Interop))
        layOut(root, 1000, 1000)
        val result = WindowMasks.compute(root)
        assertFalse(result.failClosed)
        assertEquals(listOf(MaskRect(0.0, 0.0, 1.0, 0.2), MaskRect(0.0, 0.2, 0.5, 0.3)), result.rects)
        assertEquals("""{"mode":"precise","reasons":["interop"]}""", result.coverage.toJson().toString())
    }

    @Test
    fun aWholeHostRegionIsMaskedOverItsBoundsAndReportedAsWholeHost() {
        region.masks = RegionMasks.WholeHost(MaskCoverageReason.ComposeDefault)
        layOut(root, 1000, 1000)
        val result = WindowMasks.compute(root)
        assertEquals(2, result.rects.size)
        val hostRect = result.rects[1]
        assertEquals(0.2, hostRect.y, 1e-9)
        assertEquals(0.6, hostRect.height, 1e-9)
        assertEquals(1.0, hostRect.width, 1e-9)
        assertEquals(MaskMode.WholeHost, result.coverage.mode)
        assertEquals(setOf(MaskCoverageReason.ComposeDefault), result.coverage.reasons)
    }

    @Test
    fun aRegionAskingForTheWholeFrameOrThrowingMasksTheWholeFrame() {
        layOut(root, 1000, 1000)
        region.masks = RegionMasks.WholeFrame(MaskCoverageReason.ComposeOwnerUnavailable)
        val owner = WindowMasks.compute(root)
        assertEquals(listOf(MaskRect.FULL_FRAME), owner.rects)
        assertEquals("""{"mode":"wholeFrame","reasons":["composeOwnerUnavailable"]}""", owner.coverage.toJson().toString())
        region.throwing = true
        val thrown = WindowMasks.compute(root)
        assertTrue(thrown.failClosed)
        assertEquals(setOf(MaskCoverageReason.WalkExhausted), thrown.coverage.reasons)
    }

    @Test
    fun regionMasksAreWholeFrameOffTheMainThread() {
        region.masks = RegionMasks.Rects(emptyList())
        layOut(root, 1000, 1000)
        val executor = Executors.newSingleThreadExecutor()
        val result = executor.submit<RegionMasks> { com.tugboat.android.views.region.RegionHost(host, region).masks() }.get()
        executor.shutdown()
        assertTrue(result is RegionMasks.WholeFrame)
    }

    @Test
    fun theScrollablesUnderTheTouchAreReadPerFrameDuringAGesture() {
        val clock = FakeClock()
        val recorded = RecordingFacts()
        layOut(root, 1000, 1000)
        val tracker = RegionScrollTracker(root, factClock(clock), { _, _ -> null }, recorded::emit, requestFrame = {})
        var offset = 0f
        region.scrollables = listOf(RegionScrollable(7, vertical = true, offsetPx = { offset }, maxExtentPx = { 900f }, target = { null }))
        tracker.onTouch(MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, 10f, 300f, 0))
        offset = 120f
        clock.monoUs += 16_000
        tracker.onFrame()
        tracker.onTouch(MotionEvent.obtain(0, 20, MotionEvent.ACTION_UP, 10f, 300f, 0))
        clock.monoUs += 200_000
        tracker.onFrame()
        val scrolls = recorded.inputs("scroll")
        assertEquals(listOf("start", "update", "end"), scrolls.map { it.getString("phase") })
        assertEquals(listOf(0.0, 120.0, 120.0), scrolls.map { it.getDouble("offset") })
        assertTrue(scrolls[0].getString("scrollableId").startsWith("compose-scroll-"))
        assertEquals(900.0, scrolls[1].getDouble("maxScrollExtent"), 0.0)
    }

    @Test
    fun aTouchOutsideEveryRegionHostTracksNothing() {
        val recorded = RecordingFacts()
        layOut(root, 1000, 1000)
        val tracker = RegionScrollTracker(root, factClock(), { _, _ -> null }, recorded::emit, requestFrame = {})
        var offset = 0f
        region.scrollables = listOf(RegionScrollable(7, vertical = true, offsetPx = { offset }, maxExtentPx = { null }, target = { null }))
        tracker.onTouch(MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, 10f, 100f, 0))
        offset = 50f
        tracker.onFrame()
        assertTrue(recorded.facts.isEmpty())
    }

    @Test
    fun regionFocusIsReadWhenTheHostHasViewFocusAndRecheckedAfterInput() {
        val recorded = RecordingFacts()
        val focus = FocusFactProducer(factClock(), recorded::emit)
        region.focus = RegionFocus.Other
        focus.onGlobalFocusChanged(null, host)
        assertTrue("the host has View focus, its region focus may still settle", focus.onFrame(host))
        assertTrue(recorded.facts.isEmpty())
        region.focus = RegionFocus.TextInput
        focus.onFrame(host)
        assertEquals("one tap, one settled kind", listOf("text_input"), recorded.inputs("focus").map { it.getString("kind") })

        region.focus = RegionFocus.Other
        assertTrue(focus.onFrame(host)) // still rechecking after the change
        while (focus.onFrame(host)) Unit
        focus.onInput()
        while (focus.onFrame(host)) Unit
        assertEquals(listOf("text_input", "other"), recorded.inputs("focus").map { it.getString("kind") })
    }

    @Test
    fun aRegionHostThatNeverReportsTextInputSettlesAsOther() {
        val recorded = RecordingFacts()
        val focus = FocusFactProducer(factClock(), recorded::emit)
        region.focus = RegionFocus.Other
        focus.onGlobalFocusChanged(null, host)
        while (focus.onFrame(host)) Unit
        assertEquals(listOf("other"), recorded.inputs("focus").map { it.getString("kind") })
    }
}
