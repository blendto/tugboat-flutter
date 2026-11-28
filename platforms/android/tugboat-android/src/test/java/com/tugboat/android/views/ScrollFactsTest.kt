package com.tugboat.android.views

import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ScrollView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.tugboat.android.host.FakeClock
import com.tugboat.android.views.facts.FactClock
import com.tugboat.android.views.scroll.OffsetScrollTracker
import com.tugboat.android.views.scroll.RecyclerScrollTracker
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Scroll start, update, end, and overscroll detection; offsets in dp (density 2). */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "xhdpi")
class ScrollFactsTest {
    private val clock = FakeClock(monoUs = 5_000_000)
    private val recorded = RecordingFacts()
    private var frameRequests = 0

    @Test
    fun scrollViewOffsetsStartUpdateAndEndAfterIdle() {
        val scroll = ScrollView(context).apply {
            id = android.R.id.list
            addView(View(context).apply { minimumHeight = 4_000 })
        }
        val root = FrameLayout(context).apply { addView(scroll) }
        layOut(root)
        val tracker = OffsetScrollTracker(root, FactClock(clock), anchorResolver(root)::anchorFor, recorded::emit, { frameRequests++ })
        tracker.onFrame() // discovery: offset 0 is the baseline

        scroll.scrollTo(0, 200)
        tracker.onScrollChanged()
        tracker.onFrame()
        clock.monoUs += 16_000
        scroll.scrollTo(0, 300)
        tracker.onScrollChanged()
        tracker.onFrame()
        clock.monoUs += 100_000
        tracker.onFrame()
        assertEquals("still scrolling inside the idle window", listOf("start", "update", "update"), phases())

        clock.monoUs += 60_000
        tracker.onFrame()
        assertEquals(listOf("start", "update", "update", "end"), phases())

        val inputs = recorded.inputs("scroll")
        assertEquals(0.0, inputs[0].getDouble("offset"), 0.0)
        assertEquals("vertical", inputs[0].getString("axis"))
        assertEquals("ScrollView#list", inputs[0].getJSONObject("anchor").getString("canonicalPath"))
        assertEquals(100.0, inputs[1].getDouble("offset"), 0.0)
        assertEquals(150.0, inputs[3].getDouble("offset"), 0.0)
        assertEquals((4_000 - 1_280) / 2.0, inputs[3].getDouble("maxScrollExtent"), 0.0)
        assertFalse(inputs[1].has("anchor"))
        assertEquals(1, inputs.map { it.getString("scrollableId") }.toSet().size)
        assertTrue(frameRequests > 0)
    }

    @Test
    fun scrollViewPulledPastItsTopIsOneOverscroll() {
        val (scroll, tracker) = scrollViewTracker(contentHeight = 4_000)

        touch(tracker, 100f, 300f, 100f, 700f) // finger down: the content wants to go up past its start

        assertEquals(listOf("start", "overscroll", "end"), phases())
        assertEquals(setOf("scrollableId", "phase"), recorded.inputs("scroll")[1].keys().asSequence().toSet())
        assertEquals(0, scroll.scrollY)
    }

    @Test
    fun scrollViewPulledPastItsBottomIsAnOverscrollButNotTheOtherWay() {
        val (scroll, tracker) = scrollViewTracker(contentHeight = 4_000)
        scroll.scrollTo(0, 10_000)
        tracker.onScrollChanged()
        tracker.onFrame()
        clock.monoUs += 200_000 // the scroll ends
        tracker.onFrame()
        recorded.facts.clear()

        touch(tracker, 100f, 700f, 100f, 300f) // finger up at the bottom
        assertEquals(listOf("start", "overscroll", "end"), phases())
        recorded.facts.clear()
        touch(tracker, 100f, 300f, 100f, 700f) // finger down: the list could scroll back
        assertEquals(emptyList<String>(), phases())
    }

    @Test
    fun scrollViewThatMovedDuringTheDragIsNotAnOverscroll() {
        val (scroll, tracker) = scrollViewTracker(contentHeight = 4_000)

        touch(tracker, 100f, 700f, 100f, 300f) { scroll.scrollTo(0, 200); tracker.onScrollChanged() }

        assertEquals(emptyList<String>(), phases().filter { it == "overscroll" })
    }

    @Test
    fun shortContentATapAndAnotherAxisAreNotOverscrolls() {
        val (_, fits) = scrollViewTracker(contentHeight = 100)
        touch(fits, 100f, 300f, 100f, 700f)
        assertEquals("content that fits", emptyList<String>(), phases())
        val (_, tall) = scrollViewTracker(contentHeight = 4_000)
        touch(tall, 100f, 300f, 100f, 305f) // inside the touch slop
        touch(tall, 500f, 300f, 100f, 300f) // a sideways drag on a vertical list
        assertEquals(emptyList<String>(), phases())
    }

    @Test
    fun aFlippedScrollViewReadsTheDragInItsOwnCoordinates() {
        val (scroll, tracker) = scrollViewTracker(contentHeight = 4_000)
        scroll.scaleY = -1f // an inverted FlatList

        touch(tracker, 100f, 300f, 100f, 700f) // finger down is "up" for the flipped content: it can scroll
        assertEquals(emptyList<String>(), phases())
        touch(tracker, 100f, 700f, 100f, 300f)
        assertEquals(listOf("start", "overscroll", "end"), phases())
    }

    @Test
    fun aHorizontalScrollViewPulledPastItsStartIsAnOverscroll() {
        val scroll = HorizontalScrollView(context).apply { addView(View(context).apply { minimumWidth = 4_000 }) }
        val root = FrameLayout(context).apply { addView(scroll) }
        layOut(root)
        val tracker = OffsetScrollTracker(root, FactClock(clock), { null }, recorded::emit, { frameRequests++ })
        tracker.onFrame()

        touch(tracker, 100f, 300f, 400f, 300f)

        assertEquals(listOf("start", "overscroll", "end"), phases())
        assertEquals("horizontal", recorded.inputs("scroll")[0].getString("axis"))
    }

    @Test
    fun aCancelledGestureASecondPointerAndARecyclerAreHandledOnce() {
        val (_, tracker) = scrollViewTracker(contentHeight = 4_000)
        tracker.onTouch(MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, 100f, 300f, 0))
        tracker.onTouch(MotionEvent.obtain(0, 20, MotionEvent.ACTION_POINTER_DOWN, 100f, 300f, 0))
        tracker.onTouch(MotionEvent.obtain(0, 50, MotionEvent.ACTION_UP, 100f, 700f, 0))
        assertEquals("a second pointer is not a drag", emptyList<String>(), phases())

        tracker.onTouch(MotionEvent.obtain(0, 100, MotionEvent.ACTION_DOWN, 100f, 300f, 0))
        tracker.onTouch(MotionEvent.obtain(0, 150, MotionEvent.ACTION_CANCEL, 100f, 700f, 0))
        assertEquals("a cancel is the system's gesture", emptyList<String>(), phases())

        val list = recycler(50)
        val root = list.parent as FrameLayout
        val recyclerTracker = OffsetScrollTracker(root, FactClock(clock), { null }, recorded::emit, { frameRequests++ })
        recyclerTracker.onFrame()
        recorded.facts.clear()
        touch(recyclerTracker, 100f, 300f, 100f, 700f)
        assertEquals("a RecyclerView reports through its own tracker", emptyList<String>(), phases())
    }

    @Test
    fun aScrollViewThatFitsPassesTheDragToTheOneAbove() {
        val inner = ScrollView(context).apply { addView(View(context).apply { minimumHeight = 100 }) }
        val outer = ScrollView(context).apply {
            addView(FrameLayout(context).apply { minimumHeight = 4_000; addView(inner, FrameLayout.LayoutParams(400, 400)) })
        }
        val root = FrameLayout(context).apply { addView(outer) }
        layOut(root)
        val tracker = OffsetScrollTracker(root, FactClock(clock), { null }, recorded::emit, { frameRequests++ })
        tracker.onFrame()
        recorded.facts.clear()

        touch(tracker, 100f, 100f, 100f, 300f)

        assertEquals(listOf("start", "overscroll", "end"), phases())
    }

    @Test
    fun aQuickDragThatLiftsBeforeTheNextFrameStillStartsTheScrollBeforeTheLift() {
        val (scroll, tracker) = scrollViewTracker(contentHeight = 4_000)

        tracker.onTouch(MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, 100f, 700f, 0))
        scroll.scrollTo(0, 300) // the drag moved it; no frame has run and no layout pass reported it yet
        assertEquals("nothing before the lift event arrives", emptyList<String>(), phases())
        tracker.onTouch(MotionEvent.obtain(0, 50, MotionEvent.ACTION_UP, 100f, 300f, 0))
        assertEquals("the start exists when the pointer is released", listOf("start", "update"), phases())
        assertTrue(recorded.inputs("scroll")[0].has("anchor").not())

        tracker.onFrame()
        clock.monoUs += 200_000
        tracker.onFrame()
        assertEquals("one scroll, no overscroll, no duplicate start", listOf("start", "update", "end"), phases())
    }

    private fun scrollViewTracker(contentHeight: Int): Pair<ScrollView, OffsetScrollTracker> {
        val scroll = ScrollView(context).apply { addView(View(context).apply { minimumHeight = contentHeight }) }
        val root = FrameLayout(context).apply { addView(scroll) }
        layOut(root)
        val tracker = OffsetScrollTracker(root, FactClock(clock), { null }, recorded::emit, { frameRequests++ })
        tracker.onFrame()
        recorded.facts.clear()
        return scroll to tracker
    }

    /** A window touch stream from ([fromX], [fromY]) to ([toX], [toY]); [between] runs mid-gesture. */
    private fun touch(
        tracker: OffsetScrollTracker,
        fromX: Float,
        fromY: Float,
        toX: Float,
        toY: Float,
        between: () -> Unit = {},
    ) {
        tracker.onTouch(MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, fromX, fromY, 0))
        between()
        tracker.onTouch(MotionEvent.obtain(0, 50, MotionEvent.ACTION_UP, toX, toY, 0))
    }

    @Test
    fun recyclerViewDragReportsStartUpdatesAndEnd() {
        val list = recycler(50)
        val tracker = RecyclerScrollTracker(FactClock(clock), anchorResolver(list.parent as FrameLayout)::anchorFor, recorded::emit)
        tracker.track(list)

        drag(list, fromY = 800f, toY = 500f)

        val phases = phases()
        assertEquals("start", phases.first())
        assertEquals("end", phases.last())
        assertTrue(phases.toString(), phases.drop(1).dropLast(1).all { it == "update" })
        val start = recorded.inputs("scroll").first()
        assertTrue(start.has("anchor"))
        assertEquals(0.0, start.getDouble("offset"), 0.0)
        assertTrue(recorded.inputs("scroll").last().getDouble("offset") > 0.0)
    }

    @Test
    fun recyclerViewDragAtAnEdgeThatMovesNothingIsAnOverscroll() {
        val list = recycler(50)
        val tracker = RecyclerScrollTracker(FactClock(clock), { null }, recorded::emit)
        tracker.track(list)

        // Dragging down at the top: the list cannot scroll up.
        drag(list, fromY = 300f, toY = 700f)

        assertEquals(listOf("start", "overscroll", "end"), phases())
        val overscroll = recorded.inputs("scroll")[1]
        assertEquals(setOf("scrollableId", "phase"), overscroll.keys().asSequence().toSet())
    }

    @Test
    fun programmaticRecyclerScrollIsOneShortScroll() {
        val list = recycler(50)
        val tracker = RecyclerScrollTracker(FactClock(clock), { null }, recorded::emit)
        tracker.track(list)
        list.scrollBy(0, 300)
        assertEquals(listOf("start", "update", "end"), phases())
        val offsets = recorded.inputs("scroll").map { it.getDouble("offset") }
        assertEquals(listOf(0.0, 150.0, 150.0), offsets)
    }

    private fun recycler(count: Int): RecyclerView {
        val list = RecyclerView(context).apply {
            layoutManager = LinearLayoutManager(context)
            adapter = RowAdapter(count)
        }
        layOut(FrameLayout(context).apply { addView(list) })
        return list
    }

    /**
     * A slow drag (no fling): down, three moves (the first is intercepted
     * from the row), hold, up.
     */
    private fun drag(list: RecyclerView, fromY: Float, toY: Float) {
        list.dispatchTouchEvent(MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, 100f, fromY, 0))
        for (step in 1..3) {
            val y = fromY + (toY - fromY) * step / 3
            list.dispatchTouchEvent(MotionEvent.obtain(0, step * 10L, MotionEvent.ACTION_MOVE, 100f, y, 0))
        }
        list.dispatchTouchEvent(MotionEvent.obtain(0, 1_000, MotionEvent.ACTION_MOVE, 100f, toY, 0))
        list.dispatchTouchEvent(MotionEvent.obtain(0, 1_010, MotionEvent.ACTION_UP, 100f, toY, 0))
    }

    private fun phases() = recorded.inputs("scroll").map { it.getString("phase") }
}
