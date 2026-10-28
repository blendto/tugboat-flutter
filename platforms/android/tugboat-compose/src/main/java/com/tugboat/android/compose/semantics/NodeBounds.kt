package com.tugboat.android.compose.semantics

import android.graphics.RectF
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.findRootCoordinates
import androidx.compose.ui.semantics.SemanticsNode

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
     * Mask bounds: the union of the semantics bounds (clipped) and the
     * unclipped root bounding box of the node's layout coordinates, which
     * maps through every `graphicsLayer` transform of the node and its
     * ancestors. Compose does not clip children to their parents by default,
     * so this over-masks rather than under-masks.
     */
    fun maskBounds(node: SemanticsNode): RectF {
        val bounds = bounds(node)
        val coordinates = node.layoutInfo.coordinates
        if (coordinates.isAttached) bounds.union(unclipped(coordinates))
        return bounds
    }

    /** The unclipped root bounding box of attached [coordinates], through every `graphicsLayer` transform. */
    fun unclipped(coordinates: LayoutCoordinates): RectF {
        val box = coordinates.findRootCoordinates().localBoundingBoxOf(coordinates, clipBounds = false)
        return RectF(box.left, box.top, box.right, box.bottom)
    }
}
