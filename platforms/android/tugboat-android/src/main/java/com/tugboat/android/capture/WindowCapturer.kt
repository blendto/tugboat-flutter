package com.tugboat.android.capture

import android.view.Window
import com.tugboat.capture.CaptureRequest
import com.tugboat.capture.CaptureResult
import com.tugboat.capture.CaptureRuntime

/**
 * The pixel runtime seam: `capture-runtime`'s window path in production, a
 * fake in tests (which keeps the image core's JNI library out of JVM tests).
 */
internal interface WindowCapturer {
    /**
     * Copies [window], fills masks, encodes. [onComplete] runs once, on any
     * thread, with the result for `request.requestId`.
     */
    fun capture(window: Window, request: CaptureRequest, onComplete: (CaptureResult) -> Unit)

    /** Pending captures complete with `Disposed`. */
    fun dispose()
}

/**
 * `com.tugboat.capture.CaptureRuntime.capture(Window, …)`: `PixelCopy` of the
 * window (API 26+, coverage `windowComposite`), masks filled in the C++ core
 * before JPEG encoding. Captures run one at a time on the runtime's thread.
 */
internal class RuntimeWindowCapturer(private val runtime: CaptureRuntime = CaptureRuntime()) : WindowCapturer {
    override fun capture(window: Window, request: CaptureRequest, onComplete: (CaptureResult) -> Unit) =
        runtime.capture(window, request, onComplete)

    override fun dispose() = runtime.dispose()
}
