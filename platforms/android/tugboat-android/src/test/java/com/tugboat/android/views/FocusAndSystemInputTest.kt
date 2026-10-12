package com.tugboat.android.views

import android.view.KeyEvent
import android.widget.Button
import android.widget.EditText
import com.tugboat.android.host.FakeClock
import com.tugboat.android.views.facts.FactClock
import com.tugboat.android.views.input.FocusFactProducer
import com.tugboat.android.views.input.SystemInputProducer
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class FocusAndSystemInputTest {
    private val clock = FakeClock(monoUs = 7_000_000)
    private val recorded = RecordingFacts()

    @Test
    fun focusKindsFollowTheFocusedView() {
        val focus = FocusFactProducer(FactClock(clock), recorded::emit)
        val field = EditText(context)
        val button = Button(context)

        focus.onGlobalFocusChanged(null, field)
        clock.monoUs = 7_016_000
        focus.onFrame(field)
        focus.onGlobalFocusChanged(field, field)
        focus.onFrame(field) // same kind: not repeated
        focus.onGlobalFocusChanged(field, button)
        focus.onFrame(button)
        focus.onGlobalFocusChanged(button, null)
        focus.onFrame(null)

        assertEquals(listOf("text_input", "other", "none"), recorded.inputs("focus").map { it.getString("kind") })
        assertEquals("stamped when focus changed, not at the frame", 7_000_000L, recorded.facts.first().at.monoUs)
    }

    @Test
    fun severalChangesWithinOneFrameReportWhereFocusSettled() {
        var frames = 0
        val focus = FocusFactProducer(FactClock(clock), recorded::emit) { frames++ }
        val field = EditText(context)
        val button = Button(context)

        focus.onGlobalFocusChanged(null, button)
        focus.onGlobalFocusChanged(button, field)
        assertEquals("nothing before the frame", 0, recorded.facts.size)
        assertEquals(2, frames)
        focus.onFrame(field)

        assertEquals(listOf("text_input"), recorded.inputs("focus").map { it.getString("kind") })
    }

    @Test
    fun allowlistedKeyDownsOnlyOncePerPress() {
        val keys = SystemInputProducer(FactClock(clock), recorded::emit)
        keys.onKey(key(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_BACK, repeat = 0, timeMs = 500))
        keys.onKey(key(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_BACK, repeat = 1, timeMs = 550))
        keys.onKey(key(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_BACK, repeat = 0, timeMs = 600))
        keys.onKey(key(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_A, repeat = 0, timeMs = 700))
        keys.onKey(key(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_VOLUME_UP, repeat = 0, timeMs = 800))
        keys.onKey(key(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_VOLUME_DOWN, repeat = 0, timeMs = 900))
        keys.onKey(key(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_VOLUME_MUTE, repeat = 0, timeMs = 1000))
        keys.onKey(key(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, repeat = 0, timeMs = 1100))

        assertEquals(
            listOf("back", "volume_up", "volume_down", "volume_mute", "media_play_pause"),
            recorded.inputs("systemInput").map { it.getString("input") },
        )
        assertEquals(500_000L, recorded.facts.first().at.monoUs)
    }

    private fun key(action: Int, code: Int, repeat: Int, timeMs: Long) = KeyEvent(0, timeMs, action, code, repeat)
}
