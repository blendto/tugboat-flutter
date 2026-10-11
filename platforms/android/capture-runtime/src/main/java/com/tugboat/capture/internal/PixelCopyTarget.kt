package com.tugboat.capture.internal

import android.annotation.TargetApi
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.Window
import com.tugboat.capture.CaptureStatus

/** The `PixelCopy.request` overload a resolved [CaptureSource] copies with. */
internal sealed interface PixelCopyTarget {
    /** Capture thread. False means there is no surface to copy yet. */
    fun isAvailable(): Boolean

    /**
     * Main thread. Issues `PixelCopy.request` and returns `Ok`, or returns the
     * status that forbids the copy without issuing it.
     */
    fun issue(
        destination: Bitmap,
        listener: PixelCopy.OnPixelCopyFinishedListener,
        handler: Handler,
    ): CaptureStatus
}

internal class SurfaceViewTarget(
    private val surfaceView: SurfaceView,
) : PixelCopyTarget {
    override fun isAvailable(): Boolean = surfaceView.holder.surface.isValid

    @TargetApi(Build.VERSION_CODES.N)
    override fun issue(
        destination: Bitmap,
        listener: PixelCopy.OnPixelCopyFinishedListener,
        handler: Handler,
    ): CaptureStatus {
        PixelCopy.request(surfaceView, destination, listener, handler)
        return CaptureStatus.Ok
    }
}

internal class WindowTarget(
    private val window: Window,
) : PixelCopyTarget {
    override fun isAvailable(): Boolean = window.peekDecorView()?.isAttachedToWindow == true

    /** Re-checks `FLAG_SECURE` so a flag set after resolve is still honoured. */
    @TargetApi(Build.VERSION_CODES.O)
    override fun issue(
        destination: Bitmap,
        listener: PixelCopy.OnPixelCopyFinishedListener,
        handler: Handler,
    ): CaptureStatus {
        if (window.isSecure()) return CaptureStatus.SecureWindow
        PixelCopy.request(window, destination, listener, handler)
        return CaptureStatus.Ok
    }
}
