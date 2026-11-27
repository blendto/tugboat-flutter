package com.tugboat.android.views.inventory

import android.os.Build
import android.view.View
import android.view.Window
import android.view.WindowInsets
import com.tugboat.android.views.scroll.ScrollAxis
import com.tugboat.android.views.scroll.ScrollMetrics
import org.json.JSONObject

/**
 * The exploration metadata of a `scene.inventory` (Flutter 0.11.0's
 * `surface`, `viewport` and `scroll`; stateful-engine.md section 4.3.2).
 * Text-free evidence, never hash input. All values are in logical pixels
 * (density-independent pixels), as the engine's contract says.
 */
internal object InventoryMetadata {
    /**
     * `surface {kind, widgetClass?}`: `dialog` for a floating window, else
     * `page`; `widgetClass` is the window callback's class (the activity or
     * dialog) when it has a name.
     */
    fun surface(window: Window): JSONObject {
        val kind = if (window.isFloating) "dialog" else "page"
        val json = JSONObject().put("kind", kind)
        val name = window.callback?.javaClass?.let { if (it.isAnonymousClass) null else it.simpleName }
        if (!name.isNullOrBlank()) json.put("widgetClass", name)
        return json
    }

    /** `viewport` of [decor]'s window, or null when the density is unknown. */
    fun viewport(decor: View): JSONObject? {
        val density = decor.resources.displayMetrics.density.toDouble()
        if (!(density > 0) || !density.isFinite()) return null
        val location = IntArray(2)
        decor.getLocationOnScreen(location)
        val insets = decor.rootWindowInsets
        val bars = Insets.systemBars(insets)
        return JSONObject()
            .put("widthPx", decor.width / density)
            .put("heightPx", decor.height / density)
            .put("devicePixelRatio", density)
            .put("boundaryOffset", JSONObject().put("left", location[0] / density).put("top", location[1] / density))
            .put(
                "insets",
                JSONObject()
                    .put("top", bars[0] / density)
                    .put("bottom", bars[1] / density)
                    .put("left", bars[2] / density)
                    .put("right", bars[3] / density),
            )
            .put("keyboardInset", Insets.keyboardBottom(insets) / density)
    }

    /** `scroll` of the primary vertical scrollable, from its pixel [metrics]. */
    fun scroll(metrics: ScrollMetrics, density: Double): JSONObject? {
        if (metrics.axis != ScrollAxis.Vertical || !(density > 0)) return null
        val json = JSONObject().put("offsetPx", metrics.offsetPx / density)
        metrics.maxExtentPx?.let { json.put("maxExtentPx", it / density) }
        return json
    }
}

/** The window insets the viewport reports, by API level. */
private object Insets {
    /** top, bottom, left, right in pixels; zeros when unknown. */
    @Suppress("DEPRECATION")
    fun systemBars(insets: WindowInsets?): IntArray {
        if (insets == null) return IntArray(4)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bars = insets.getInsets(WindowInsets.Type.systemBars())
            return intArrayOf(bars.top, bars.bottom, bars.left, bars.right)
        }
        return intArrayOf(
            insets.systemWindowInsetTop,
            insets.systemWindowInsetBottom,
            insets.systemWindowInsetLeft,
            insets.systemWindowInsetRight,
        )
    }

    /** The on-screen keyboard's height in pixels (API 30+); 0 when closed or unknown. */
    fun keyboardBottom(insets: WindowInsets?): Int {
        if (insets == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return 0
        return insets.getInsets(WindowInsets.Type.ime()).bottom
    }
}
