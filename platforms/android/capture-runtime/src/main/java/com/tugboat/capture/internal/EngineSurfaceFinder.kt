package com.tugboat.capture.internal

import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import com.tugboat.capture.RenderMode

internal data class EngineSurface(
    val renderMode: RenderMode,
    val surfaceView: SurfaceView?,
)

/**
 * Finds the engine surface by class name. Known gap: a hybrid composition
 * platform view makes Flutter pause the `FlutterSurfaceView` and render into
 * a `FlutterImageView`. That view is not looked for here, so the paused
 * surface is still reported as [RenderMode.SurfaceView] and copied. The copy
 * fails (`PixelCopyFailed`, then fallback) or returns the last frame drawn
 * before the switch, older than its masks. See
 * docs/architecture/native-capture-contracts.md (Coverage) and BLE-693.
 */
internal object EngineSurfaceFinder {
    private const val SURFACE_VIEW = "io.flutter.embedding.android.FlutterSurfaceView"
    private const val TEXTURE_VIEW = "io.flutter.embedding.android.FlutterTextureView"

    fun inspect(root: View): EngineSurface {
        var surfaceView: SurfaceView? = null
        var texture = false
        walk(root) { view ->
            when (view.javaClass.name) {
                SURFACE_VIEW -> if (view is SurfaceView) surfaceView = view
                TEXTURE_VIEW -> texture = true
            }
        }
        val mode =
            when {
                surfaceView != null && texture -> RenderMode.Hybrid
                surfaceView != null -> RenderMode.SurfaceView
                texture -> RenderMode.TextureView
                else -> RenderMode.Unknown
            }
        return EngineSurface(mode, surfaceView)
    }

    private fun walk(view: View, visit: (View) -> Unit) {
        visit(view)
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                walk(view.getChildAt(i), visit)
            }
        }
    }
}
