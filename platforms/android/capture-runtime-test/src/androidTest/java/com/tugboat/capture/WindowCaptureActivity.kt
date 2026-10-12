package com.tugboat.capture

import android.app.Activity
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import android.view.View
import android.widget.FrameLayout
import java.util.concurrent.CountDownLatch

/**
 * A window that is one known colour edge to edge, with an optional marker
 * square (a stand-in for a text view) that tests can move.
 */
class WindowCaptureActivity : Activity() {
    /** Counts down once the focused window has presented two more frames. */
    val presented = CountDownLatch(1)
    private lateinit var content: FrameLayout

    /** Hidden until [moveMarkerTo]; a quarter of the window wide and an eighth tall. */
    lateinit var marker: View
        private set

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        content = FrameLayout(this)
        marker = View(this).apply {
            setBackgroundColor(MARKER)
            visibility = View.GONE
        }
        content.addView(marker)
        setContentView(content)
        fill(FILL)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) afterTwoFrames { presented.countDown() }
    }

    /** Main thread. Paints the whole window [color]. */
    fun fill(color: Int) {
        window.setBackgroundDrawable(ColorDrawable(color))
        content.setBackgroundColor(color)
    }

    /** Main thread. Shows the marker with its top-left corner at ([x], [y]) of the decor view, as fractions. */
    fun moveMarkerTo(x: Double, y: Double) {
        val decor = window.decorView
        marker.layoutParams = FrameLayout.LayoutParams(decor.width / 4, decor.height / 8)
        marker.translationX = (x * decor.width).toFloat()
        marker.translationY = (y * decor.height).toFloat()
        marker.visibility = View.VISIBLE
    }

    /** Main thread. Runs [action] once the frame drawn after this call is on screen. */
    fun afterTwoFrames(action: () -> Unit) {
        val decor = window.decorView
        decor.postOnAnimation { decor.postOnAnimation(action) }
    }

    companion object {
        const val FILL: Int = 0xFF20C060.toInt()
        const val MARKER: Int = 0xFF2040E0.toInt()
    }
}
