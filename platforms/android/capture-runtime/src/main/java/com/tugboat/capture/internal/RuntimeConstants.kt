package com.tugboat.capture.internal

/** Source of the values the public `CaptureRuntime` companion re-exports. */
internal object RuntimeConstants {
    /** `PixelCopy.request(SurfaceView, …)`. */
    const val MIN_NATIVE_API: Int = 24

    /** `PixelCopy.request(Window, …)`. */
    const val MIN_WINDOW_API: Int = 26

    const val JPEG_QUALITY: Int = 80
}
