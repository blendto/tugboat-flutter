package com.tugboat.android.views

import android.view.MotionEvent
import com.tugboat.android.host.FakeClock
import com.tugboat.android.views.facts.FactClock
import com.tugboat.android.views.identity.TapEvidence
import com.tugboat.android.views.input.GestureConfig
import com.tugboat.android.views.input.PointerFactProducer
import com.tugboat.android.views.input.SurfaceOffset
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class PointerFactProducerTest {
    private val clock = FakeClock(monoUs = 10_000_000, wallUs = 1_800_000_000_000_000)
    private val recorded = RecordingFacts()
    private val taps = ArrayList<Pair<Float, Float>>()
    private val producer = PointerFactProducer(
        clock = FactClock(clock),
        gesture = GestureConfig(touchSlop = 8.0, panSlop = 16.0, scaleSlop = 16.0),
        density = { DENSITY },
        resolveTap = { x, y ->
            taps += x to y
            TapEvidence.failed(TapEvidence.NO_TARGET_AT_POINT)
        },
        emit = recorded::emit,
    )

    @Test
    fun singleTapSendsDownAndUpWithTapEvidenceAtTheDownPosition() {
        producer.onTouch(event(MotionEvent.ACTION_DOWN, 0, 1_000, pointer(0, 100f, 200f)))
        producer.onTouch(event(MotionEvent.ACTION_UP, 0, 1_080, pointer(0, 104f, 202f)))

        val facts = recorded.facts
        assertEquals(listOf("down", "up"), facts.map { it.input.getString("phase") })
        val down = facts[0].input
        assertEquals(50.0, down.getDouble("x"), 0.0)
        assertEquals(100.0, down.getDouble("y"), 0.0)
        assertEquals("touch", down.getString("device"))
        assertFalse(down.has("tap"))
        assertEquals(facts[0].input.getLong("pointerId"), facts[1].input.getLong("pointerId"))
        assertEquals(1_000_000L, facts[0].at.monoUs)
        assertEquals(1_080_000L, facts[1].at.monoUs)
        assertEquals(clock.wallUs - (clock.monoUs - 1_080_000L), facts[1].at.wallUs)
        assertEquals(JSONObject().put("failureReason", "no_target_at_point").toString(), facts[1].input.getJSONObject("tap").toString())
        assertEquals(listOf(100f to 200f), taps)
    }

    @Test
    fun travelAtTouchSlopIsNoTapAndJustBelowIs() {
        // 8 dp is 16 px at density 2: the engine's swipe test is distance >= touchSlop.
        tapWithTravel(16f)
        assertFalse(recorded.facts.last().input.has("tap"))

        recorded.facts.clear()
        tapWithTravel(15.9f)
        assertTrue(recorded.facts.last().input.has("tap"))
    }

    @Test
    fun travelIsTheLargestDistanceNotTheFinalOne() {
        producer.onTouch(event(MotionEvent.ACTION_DOWN, 0, 0, pointer(0, 0f, 0f)))
        producer.onTouch(event(MotionEvent.ACTION_MOVE, 0, 10, pointer(0, 40f, 0f)))
        producer.onTouch(event(MotionEvent.ACTION_UP, 0, 20, pointer(0, 0f, 0f)))
        assertFalse(recorded.facts.last().input.has("tap"))
    }

    @Test
    fun recycledAndroidPointerIdsGetNewMonotonicContactIds() {
        producer.onTouch(event(MotionEvent.ACTION_DOWN, 0, 0, pointer(0, 10f, 10f)))
        producer.onTouch(event(MotionEvent.ACTION_POINTER_DOWN, 1, 5, pointer(0, 10f, 10f), pointer(1, 300f, 300f)))
        producer.onTouch(event(MotionEvent.ACTION_POINTER_UP, 0, 10, pointer(0, 10f, 10f), pointer(1, 300f, 300f)))
        // Android reuses id 0 for the next finger.
        producer.onTouch(event(MotionEvent.ACTION_POINTER_DOWN, 1, 15, pointer(1, 300f, 300f), pointer(0, 50f, 50f)))
        producer.onTouch(event(MotionEvent.ACTION_MOVE, 0, 20, pointer(1, 302f, 300f), pointer(0, 52f, 50f)))

        val phases = recorded.facts.map { it.input.getString("phase") to it.input.getLong("pointerId") }
        val first = phases[0].second
        assertEquals(
            listOf("down" to first, "down" to first + 1, "up" to first, "down" to first + 2, "move" to first + 1, "move" to first + 2),
            phases,
        )
    }

    @Test
    fun cancelEndsEveryOpenContactWithoutTapEvidence() {
        producer.onTouch(event(MotionEvent.ACTION_DOWN, 0, 0, pointer(0, 10f, 10f)))
        producer.onTouch(event(MotionEvent.ACTION_POINTER_DOWN, 1, 5, pointer(0, 10f, 10f), pointer(1, 90f, 90f)))
        producer.onTouch(event(MotionEvent.ACTION_CANCEL, 0, 10, pointer(0, 10f, 10f), pointer(1, 90f, 90f)))

        val cancels = recorded.facts.filter { it.input.getString("phase") == "cancel" }
        assertEquals(2, cancels.size)
        assertTrue(cancels.none { it.input.has("tap") })
        assertTrue(taps.isEmpty())
    }

    @Test
    fun aDownAfterALostUpCancelsTheStaleContactFirst() {
        producer.onTouch(event(MotionEvent.ACTION_DOWN, 0, 0, pointer(0, 10f, 10f)))
        producer.onTouch(event(MotionEvent.ACTION_DOWN, 0, 50, pointer(0, 20f, 20f)))

        assertEquals(listOf("down", "cancel", "down"), recorded.facts.map { it.input.getString("phase") })
        assertEquals(recorded.facts[0].input.getLong("pointerId"), recorded.facts[1].input.getLong("pointerId"))
    }

    @Test
    fun toolTypesMapToEngineDevices() {
        producer.onTouch(event(MotionEvent.ACTION_DOWN, 0, 0, pointer(0, 1f, 1f, MotionEvent.TOOL_TYPE_STYLUS)))
        producer.onTouch(event(MotionEvent.ACTION_UP, 0, 1, pointer(0, 1f, 1f, MotionEvent.TOOL_TYPE_STYLUS)))
        producer.onTouch(event(MotionEvent.ACTION_DOWN, 0, 2, pointer(0, 1f, 1f, MotionEvent.TOOL_TYPE_MOUSE)))
        assertEquals(listOf("stylus", "stylus", "mouse"), recorded.facts.map { it.input.getString("device") })
    }

    @Test
    fun aDialogWindowReportsSurfacePositionsAndResolvesTapsInItsOwnSpace() {
        val offset = SurfaceOffset(40f, 600f)
        val dialog = PointerFactProducer(
            clock = FactClock(clock),
            gesture = GestureConfig(touchSlop = 8.0, panSlop = 16.0, scaleSlop = 16.0),
            density = { DENSITY },
            resolveTap = { x, y ->
                taps += x to y
                TapEvidence.failed(TapEvidence.NO_TARGET_AT_POINT)
            },
            emit = recorded::emit,
            surfaceOffset = { offset },
        )

        dialog.onTouch(event(MotionEvent.ACTION_DOWN, 0, 0, pointer(0, 100f, 200f)))
        dialog.onTouch(event(MotionEvent.ACTION_UP, 0, 10, pointer(0, 102f, 201f)))

        val (down, up) = recorded.facts.map { it.input }
        assertEquals(70.0, down.getDouble("x"), 0.0)
        assertEquals(400.0, down.getDouble("y"), 0.0)
        assertEquals(71.0, up.getDouble("x"), 0.0)
        assertEquals(400.5, up.getDouble("y"), 0.0)
        assertTrue(up.has("tap"))
        assertEquals("hit-tested in the dialog window, without the offset", listOf(100f to 200f), taps)
    }

    @Test
    fun surfaceOffsetIsTheDifferenceOfOnScreenLocations() {
        assertEquals(SurfaceOffset(60f, 652f), SurfaceOffset.between(60, 700, 0, 48))
        assertEquals(SurfaceOffset(-1080f, 0f), SurfaceOffset.between(0, 0, 1080, 0))
        assertEquals(SurfaceOffset.ZERO, SurfaceOffset.between(12, 34, 12, 34))
    }

    private fun tapWithTravel(px: Float) {
        producer.onTouch(event(MotionEvent.ACTION_DOWN, 0, 0, pointer(0, 100f, 100f)))
        producer.onTouch(event(MotionEvent.ACTION_MOVE, 0, 10, pointer(0, 100f + px, 100f)))
        producer.onTouch(event(MotionEvent.ACTION_UP, 0, 20, pointer(0, 100f + px, 100f)))
    }

    private class Pointer(val id: Int, val x: Float, val y: Float, val tool: Int)

    private fun pointer(id: Int, x: Float, y: Float, tool: Int = MotionEvent.TOOL_TYPE_FINGER) = Pointer(id, x, y, tool)

    private fun event(action: Int, actionIndex: Int, timeMs: Long, vararg pointers: Pointer): MotionEvent {
        val properties = pointers.map { p -> MotionEvent.PointerProperties().apply { id = p.id; toolType = p.tool } }
        val coords = pointers.map { p -> MotionEvent.PointerCoords().apply { x = p.x; y = p.y } }
        val masked = action or (actionIndex shl MotionEvent.ACTION_POINTER_INDEX_SHIFT)
        return MotionEvent.obtain(
            0, timeMs, masked, pointers.size, properties.toTypedArray(), coords.toTypedArray(),
            0, 0, 1f, 1f, 0, 0, 0, 0,
        )
    }

    private companion object {
        const val DENSITY = 2f
    }
}
