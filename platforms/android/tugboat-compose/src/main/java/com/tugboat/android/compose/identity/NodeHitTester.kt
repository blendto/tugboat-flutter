package com.tugboat.android.compose.identity

import androidx.compose.ui.semantics.SemanticsNode
import com.tugboat.android.compose.semantics.NodeBounds
import com.tugboat.android.compose.semantics.NodeRules

/**
 * Finds the semantics nodes a touch at a point lands on, the way Compose
 * pointer dispatch tries them: topmost first (reverse paint order), only
 * inside a node's touch bounds. A subtree without an actionable node would
 * not consume the touch, so dispatch moves on to the siblings below it; the
 * chain of the first subtree that would is returned, else the deepest chain
 * under the point. Excluded nodes ([NodeRules.isExcluded]) are skipped.
 */
internal object NodeHitTester {
    /** The nodes under ([x], [y]) in host pixels, from below [root] down to the deepest; empty when none. */
    fun hit(root: SemanticsNode, x: Float, y: Float): List<SemanticsNode> = children(root, x, y)?.chain.orEmpty()

    private class Hit(val chain: List<SemanticsNode>, val consumed: Boolean)

    private fun visit(node: SemanticsNode, x: Float, y: Float): Hit? {
        if (NodeRules.isExcluded(node) || !NodeBounds.touches(node, x, y)) return null
        val below = children(node, x, y)
        val chain = listOf(node) + below?.chain.orEmpty()
        return Hit(chain, consumed = below?.consumed == true || NodeRules.isActionable(node))
    }

    private fun children(node: SemanticsNode, x: Float, y: Float): Hit? {
        var fallback: Hit? = null
        for (child in node.children.asReversed()) {
            val hit = visit(child, x, y) ?: continue
            if (hit.consumed) return hit
            if (fallback == null) fallback = hit
        }
        return fallback
    }
}
