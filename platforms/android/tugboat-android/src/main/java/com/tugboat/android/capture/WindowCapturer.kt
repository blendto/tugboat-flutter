package com.tugboat.android.capture

import android.view.Window
import com.tugboat.capture.CaptureRequest
import com.tugboat.capture.CaptureResult
import com.tugboat.capture.CaptureRuntime
import com.tugboat.capture.WindowMaskSupplier

/**
 * The pixel runtime seam: `capture-runtime`'s window path in production, a
 * fake in tests (which keeps the image core's JNI library out of JVM tests).
 */
internal interface WindowCapturer {
    /**
     * Copies [window], filling the masks [masks] returns on the main thread
     * right before the copy, and encodes. [onComplete] runs once, on any
     * thread, with the result for `request.requestId`.
     */
    fun capture(window: Window, request: CaptureRequest, masks: WindowMaskSupplier, onComplete: (CaptureResult) -> Unit)

    /** Pending captures complete with `Disposed`. */
    fun dispose()
}

/**
 * `com.tugboat.capture.CaptureRuntime.capture(Window, …, WindowMaskSupplier, …)`:
 * `PixelCopy` of the window (API 26+, coverage `windowComposite`), masks
 * taken for the copied frame and filled in the C++ core before JPEG
 * encoding. Captures run one at a time on the runtime's thread.
 */
internal class RuntimeWindowCapturer(private val runtime: CaptureRuntime = CaptureRuntime()) : WindowCapturer {
    override fun capture(
        window: Window,
        request: CaptureRequest,
        masks: WindowMaskSupplier,
        onComplete: (CaptureResult) -> Unit,
    ) = runtime.capture(window, request, masks, onComplete)

    override fun dispose() = runtime.dispose()
}
