package com.tugboat.android.views

import android.app.Activity
import android.app.Application
import android.os.Looper
import android.os.SystemClock
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.Window
import com.tugboat.android.host.FakeClock
import com.tugboat.android.views.input.GestureConfig
import com.tugboat.android.views.navigation.NavigationObservation
import org.json.JSONObject
import org.robolectric.Shadows.shadowOf

/**
 * A started Views adapter for dialog-window tests: facts leave only when the
 * test runs frames ([drainFacts]), and dialog decors sit wherever [locations]
 * says on screen (Robolectric puts every window at 0,0).
 */
internal class DialogHarness {
    val sink = RecordingSink()
    val frames = ManualFrames()

    /** On-screen positions by view; unlisted views are at 0,0. */
    val locations = HashMap<View, Pair<Int, Int>>()

    val adapter: ViewsAdapter

    init {
        NavigationObservation.resetForTests()
        NavigationObservation.setFrameSchedulerForTests(frames)
        adapter = ViewsAdapter(
            application = context as Application,
            sink = sink,
            hostClock = FakeClock(monoUs = 50_000_000),
            frames = frames,
            gesture = GestureConfig(touchSlop = 8.0, panSlop = 16.0, scaleSlop = 16.0),
            locateOnScreen = { view, out ->
                val (x, y) = locations[view] ?: (0 to 0)
                out[0] = x
                out[1] = y
            },
        ).apply { start() }
    }

    fun stop() {
        adapter.stop()
        NavigationObservation.resetForTests()
    }

    /** Runs frames until none is pending (bounded) and returns the facts posted since the last call. */
    fun drainFacts(): List<Pair<String, JSONObject>> {
        repeat(MAX_FRAMES) { if (frames.hasPending) frames.runFrame() }
        val facts = sink.batches.flatten().map { it.type to JSONObject(it.inputJson) }
        sink.batches.clear()
        return facts
    }

    fun pointerUps(): List<JSONObject> =
        drainFacts().filter { it.first == "input.pointer" && it.second.getString("phase") == "up" }.map { it.second }

    private companion object {
        const val MAX_FRAMES = 20
    }
}

internal fun idleMain() = shadowOf(Looper.getMainLooper()).idle()

/** The activity window lost or regained focus (Robolectric never moves window focus). */
internal fun Activity.windowFocus(hasFocus: Boolean) {
    window.callback.onWindowFocusChanged(hasFocus)
    idleMain()
}

/** [view]'s center in its window's (decor) pixels. */
internal fun centerInWindow(view: View): Pair<Float, Float> {
    val location = IntArray(2)
    view.getLocationInWindow(location)
    return location[0] + view.width / 2f to location[1] + view.height / 2f
}

/** A down and an up at ([x], [y]) through [window]'s callback, as the window would deliver them. */
internal fun tapThrough(window: Window, x: Float, y: Float) {
    val now = SystemClock.uptimeMillis()
    for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
        val event = MotionEvent.obtain(now, now, action, x, y, 0)
        window.callback.dispatchTouchEvent(event)
        event.recycle()
    }
}

internal fun tapThrough(window: Window, view: View) {
    val (x, y) = centerInWindow(view)
    tapThrough(window, x, y)
}

internal fun backThrough(window: Window) {
    window.callback.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_BACK))
    window.callback.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_BACK))
}

internal fun JSONObject.tapAnchor(): JSONObject = getJSONObject("tap").getJSONObject("anchor")
