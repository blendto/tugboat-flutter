package com.tugboat.android.views.identity

import android.view.View
import android.view.ViewGroup

/**
 * Finds the view a touch at a point lands on, the way touch dispatch would
 * try children: highest `z` first, then the last-added child first. A child
 * subtree with no actionable view would not consume the touch, so dispatch
 * moves on to the siblings below it; the deepest view of the first subtree
 * that would is returned. When none would, the deepest view under the point.
 * Excluded views ([ViewRules.isExcluded]) and their subtrees are skipped.
 */
internal object HitTester {
    /** The view under ([x], [y]) in [root]'s coordinates, or null. */
    fun hit(root: View, x: Float, y: Float): View? {
        if (ViewRules.isExcluded(root) || !ViewGeometry.contains(root, x, y)) return null
        return visit(root, x, y).view
    }

    private class Hit(val view: View, val consumed: Boolean)

    private fun visit(view: View, x: Float, y: Float): Hit {
        var fallback: View? = null
        if (view is ViewGroup) {
            for (child in childrenTopmostFirst(view)) {
                if (ViewRules.isExcluded(child)) continue
                val local = ViewGeometry.toChild(child, x, y) ?: continue
                if (!ViewGeometry.contains(child, local[0], local[1])) continue
                val hit = visit(child, local[0], local[1])
                if (hit.consumed) return hit
                if (fallback == null) fallback = hit.view
            }
        }
        if (ViewRules.isActionable(view)) return Hit(fallback ?: view, consumed = true)
        return Hit(fallback ?: view, consumed = false)
    }

    private fun childrenTopmostFirst(group: ViewGroup): List<View> {
        val children = (0 until group.childCount).map(group::getChildAt).asReversed()
        // Stable sort: equal z keeps the last-added-first order.
        return children.sortedByDescending { it.z }
    }
}
