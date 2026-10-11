package com.tugboat.capture.internal

import android.view.View
import android.view.Window
import android.view.WindowManager
import com.tugboat.capture.CaptureCoverage
import com.tugboat.capture.CaptureRuntime
import com.tugboat.capture.CaptureStatus
import com.tugboat.capture.RenderMode

/**
 * What a capture copies pixels from. This is the only thing that differs
 * between capture entry points; everything else runs in [CapturePipeline].
 */
internal sealed interface CaptureSource {
    /** Lowest API level whose `PixelCopy` overload this source needs. */
    val minApi: Int

    /** Coverage reported on `Ok` and `SkippedByDHash`. */
    val coverage: CaptureCoverage

    /** Runs on the capture thread before any bitmap is allocated. */
    fun resolve(): SourceResolution
}

internal sealed interface SourceResolution {
    class Ready(
        val target: PixelCopyTarget,
        val renderMode: RenderMode,
    ) : SourceResolution

    class Rejected(
        val status: CaptureStatus,
        val renderMode: RenderMode,
    ) : SourceResolution
}

/** The active `FlutterSurfaceView` under [root]. Coverage `EngineSurface`. */
internal class FlutterSurfaceSource(
    private val root: View,
) : CaptureSource {
    override val minApi: Int = CaptureRuntime.MIN_NATIVE_API
    override val coverage: CaptureCoverage = CaptureCoverage.EngineSurface

    override fun resolve(): SourceResolution {
        val surface = EngineSurfaceFinder.inspect(root)
        val surfaceView = surface.surfaceView
        if (surface.renderMode != RenderMode.SurfaceView || surfaceView == null) {
            return SourceResolution.Rejected(CaptureStatus.UnsupportedRenderMode, surface.renderMode)
        }
        return SourceResolution.Ready(SurfaceViewTarget(surfaceView), surface.renderMode)
    }
}

/**
 * An app window composited by `PixelCopy.request(Window, …)`. Coverage
 * `WindowComposite`. Secure windows are rejected before any copy.
 */
internal class WindowSource(
    private val window: Window,
) : CaptureSource {
    override val minApi: Int = CaptureRuntime.MIN_WINDOW_API
    override val coverage: CaptureCoverage = CaptureCoverage.WindowComposite

    override fun resolve(): SourceResolution =
        if (window.isSecure()) {
            SourceResolution.Rejected(CaptureStatus.SecureWindow, RenderMode.Unknown)
        } else {
            SourceResolution.Ready(WindowTarget(window), RenderMode.Unknown)
        }
}

internal fun Window.isSecure(): Boolean =
    attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0
