package com.tugboat.capture

import android.app.Activity
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import android.view.View
import java.util.concurrent.CountDownLatch

/** A window that is one known colour edge to edge. */
class WindowCaptureActivity : Activity() {
    /** Counts down once the focused window has presented two more frames. */
    val presented = CountDownLatch(1)
    private lateinit var content: View

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        content = View(this)
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

    /** Main thread. Runs [action] once the frame drawn after this call is on screen. */
    fun afterTwoFrames(action: () -> Unit) {
        val decor = window.decorView
        decor.postOnAnimation { decor.postOnAnimation(action) }
    }

    companion object {
        const val FILL: Int = 0xFF20C060.toInt()
    }
}
