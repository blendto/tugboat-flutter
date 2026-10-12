package com.tugboat.android.compose.semantics

import android.graphics.RectF
import androidx.compose.ui.semantics.SemanticsNode
import kotlin.math.max
import kotlin.math.min

/** Semantics node geometry in host (`AndroidComposeView`) pixels, which is Compose's root space. */
internal object NodeBounds {
    /** Layout bounds, clipped by ancestors: identity geometry. */
    fun bounds(node: SemanticsNode): RectF = node.boundsInRoot.let { RectF(it.left, it.top, it.right, it.bottom) }

    /** Whether ([x], [y]) is inside [node]'s touch bounds (its bounds grown to the minimum touch target). */
    fun touches(node: SemanticsNode, x: Float, y: Float): Boolean {
        val touch = node.touchBoundsInRoot
        return x >= touch.left && x < touch.right && y >= touch.top && y < touch.bottom
    }

    /**
     * Mask bounds: the union of the clipped bounds and the unclipped layout
     * box, because Compose does not clip children to their parents by
     * default. Over-masks rather than under-masks.
     */
    fun maskBounds(node: SemanticsNode): RectF {
        val clipped = node.boundsInRoot
        val origin = node.positionInRoot
        val right = origin.x + node.size.width
        val bottom = origin.y + node.size.height
        return RectF(
            min(clipped.left, origin.x),
            min(clipped.top, origin.y),
            max(clipped.right, right),
            max(clipped.bottom, bottom),
        )
    }
}
