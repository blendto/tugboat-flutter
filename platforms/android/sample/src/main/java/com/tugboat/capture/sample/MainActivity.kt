package com.tugboat.capture.sample

import android.app.Activity
import android.os.Bundle
import android.widget.TextView
import com.tugboat.capture.CaptureRuntime

class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val runtime = CaptureRuntime()
        val caps = runtime.capabilities()
        val view = TextView(this)
        view.text =
            "native=${caps.nativeCaptureSupported} api=${caps.apiLevel} min=${caps.minNativeApi}"
        setContentView(view)
        runtime.dispose()
    }
}
