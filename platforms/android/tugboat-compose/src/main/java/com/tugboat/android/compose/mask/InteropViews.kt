package com.tugboat.android.compose.mask

import android.graphics.RectF
import android.view.View
import android.view.ViewGroup

/**
 * `AndroidView` interop inside a Compose host (native SDK note 2.1): every
 * View under the host that is not one of Compose's own container or layer
 * views (`androidx.compose.ui.platform`, `androidx.compose.ui.graphics.layer.view`)
 * is interop content, fail-closed over its whole bounds and not walked.
 * An unknown or renamed class therefore over-masks, never under-masks.
 */
internal object InteropViews {
    private val COMPOSE_PACKAGES = listOf("androidx.compose.ui.platform.", "androidx.compose.ui.graphics.layer.view.")

    /** Interop bounds in [host] pixels. */
    fun bounds(host: View): List<RectF> {
        val out = ArrayList<RectF>()
        if (host is ViewGroup) children(host).forEach { collect(host, it, out) }
        return out
    }

    /** True when ([x], [y]) in [host] pixels is on interop content: the Views rules resolve it. */
    fun contains(host: View, x: Float, y: Float): Boolean = bounds(host).any { it.contains(x, y) }

    private fun collect(host: View, view: View, out: MutableList<RectF>) {
        if (view.visibility != View.VISIBLE) return
        if (!isComposeOwn(view)) {
            boundsIn(host, view)?.let(out::add)
            return
        }
        if (view is ViewGroup) children(view).forEach { collect(host, it, out) }
    }

    private fun isComposeOwn(view: View): Boolean = COMPOSE_PACKAGES.any { view.javaClass.name.startsWith(it) }

    private fun children(group: ViewGroup): List<View> = (0 until group.childCount).map(group::getChildAt)

    /** [view]'s bounds in [host]'s coordinates, with transforms; null when it is not a descendant. */
    private fun boundsIn(host: View, view: View): RectF? {
        val rect = RectF(0f, 0f, view.width.toFloat(), view.height.toFloat())
        var current = view
        while (current !== host) {
            if (!current.matrix.isIdentity) current.matrix.mapRect(rect)
            rect.offset(current.left.toFloat(), current.top.toFloat())
            val parent = current.parent as? View ?: return null
            rect.offset(-parent.scrollX.toFloat(), -parent.scrollY.toFloat())
            current = parent
        }
        return rect.takeIf { it.width() > 0f && it.height() > 0f }
    }
}
