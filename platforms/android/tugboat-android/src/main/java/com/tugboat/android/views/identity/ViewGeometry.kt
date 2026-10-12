package com.tugboat.android.views.identity

import android.graphics.Matrix
import android.graphics.RectF
import android.view.View

/**
 * View geometry from public properties only (`left`/`top`, scroll, and the
 * view's transformation `matrix`), so it works on every API level and in
 * Robolectric. Main thread only.
 */
internal object ViewGeometry {
    private val scratch = FloatArray(2)
    private val inverse = Matrix()

    /** [view]'s bounds in [root]'s coordinates, or null when it is not a descendant. */
    fun boundsIn(root: View, view: View): RectF? =
        mapRect(root, view, RectF(0f, 0f, view.width.toFloat(), view.height.toFloat()))

    /** [local], in [view]'s own coordinates, mapped into [root]'s; null when it is not a descendant. */
    fun mapRect(root: View, view: View, local: RectF): RectF? {
        val rect = RectF(local)
        var current = view
        while (current !== root) {
            if (!current.matrix.isIdentity) current.matrix.mapRect(rect)
            rect.offset(current.left.toFloat(), current.top.toFloat())
            val parent = current.parent as? View ?: return null
            rect.offset(-parent.scrollX.toFloat(), -parent.scrollY.toFloat())
            current = parent
        }
        return rect
    }

    /**
     * Maps ([x], [y]) in [child]'s parent's coordinates into [child]'s own,
     * or null when its transform cannot be inverted.
     */
    fun toChild(child: View, x: Float, y: Float): FloatArray? {
        val parent = child.parent as? View ?: return null
        scratch[0] = x + parent.scrollX - child.left
        scratch[1] = y + parent.scrollY - child.top
        val matrix = child.matrix
        if (!matrix.isIdentity) {
            if (!matrix.invert(inverse)) return null
            inverse.mapPoints(scratch)
        }
        return floatArrayOf(scratch[0], scratch[1])
    }

    /** Maps ([x], [y]) in [root]'s coordinates into its descendant [view]'s, or null. */
    fun toDescendant(root: View, view: View, x: Float, y: Float): FloatArray? {
        val chain = ArrayList<View>()
        var current = view
        while (current !== root) {
            chain += current
            current = current.parent as? View ?: return null
        }
        var point = floatArrayOf(x, y)
        for (child in chain.asReversed()) point = toChild(child, point[0], point[1]) ?: return null
        return point
    }

    fun contains(view: View, localX: Float, localY: Float): Boolean =
        localX >= 0f && localY >= 0f && localX < view.width && localY < view.height
}
