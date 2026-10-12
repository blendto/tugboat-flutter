package com.tugboat.android.views

import android.app.Activity
import android.os.Bundle
import android.widget.EditText
import com.tugboat.android.host.FakeClock
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

/**
 * Focus is app-wide (Dart's `FocusManager`): navigating from a focused text
 * field to another activity reports that activity's focus, and coming back
 * reports the field again.
 */
@RunWith(RobolectricTestRunner::class)
class FocusAcrossWindowsTest {
    private val sink = RecordingSink()
    private val frames = ManualFrames()
    private val adapter = ViewsAdapter(
        application = context as android.app.Application,
        sink = sink,
        hostClock = FakeClock(),
        frames = frames,
        postNavigationFacts = true,
    ).apply { start() }

    @After
    fun stop() = adapter.stop()

    @Test
    fun leavingAFocusedFieldForAnotherActivityReportsTheLoss() {
        val first = Robolectric.buildActivity(FieldActivity::class.java).setup()
        first.get().field.requestFocus()
        assertEquals(listOf("text_input"), focusKinds())

        first.pause()
        val second = Robolectric.buildActivity(PlainActivity::class.java).setup()
        first.stop()
        val loss = focusKinds()
        assertEquals(1, loss.size)
        assertTrue(loss.single(), loss.single() in setOf("none", "other"))

        second.get().finish()
        second.pause()
        first.restart().start().resume()
        assertEquals("back on the field", listOf("text_input"), focusKinds())
    }

    @Test
    fun aWindowWhoseFocusMatchesTheLastKindReportsNothing() {
        Robolectric.buildActivity(PlainActivity::class.java).setup()
        val firstKinds = focusKinds()
        Robolectric.buildActivity(PlainActivity::class.java).setup()
        assertEquals(1, firstKinds.size)
        assertEquals("same kind in the next window: coalesced", emptyList<String>(), focusKinds())
    }

    /** Runs pending frames and returns the focus kinds posted since the last call. */
    private fun focusKinds(): List<String> {
        sink.batches.clear()
        repeat(MAX_FRAMES) { if (frames.hasPending) frames.runFrame() }
        return sink.batches.flatten().filter { it.type == "focus" }.map { JSONObject(it.inputJson).getString("kind") }
    }

    class FieldActivity : Activity() {
        lateinit var field: EditText

        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            field = EditText(this)
            setContentView(field)
        }
    }

    class PlainActivity : Activity()

    private companion object {
        const val MAX_FRAMES = 20
    }
}
