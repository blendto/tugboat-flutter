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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setBackgroundDrawable(ColorDrawable(FILL))
        setContentView(View(this).apply { setBackgroundColor(FILL) })
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus) return
        val decor = window.decorView
        decor.postOnAnimation { decor.postOnAnimation { presented.countDown() } }
    }

    companion object {
        const val FILL: Int = 0xFF20C060.toInt()
    }
}
