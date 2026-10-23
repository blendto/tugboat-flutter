package com.tugboat.android.compose.identity

import androidx.compose.ui.semantics.SemanticsNode
import com.tugboat.android.compose.semantics.NodeBounds
import com.tugboat.android.compose.semantics.NodeRoles
import com.tugboat.android.compose.semantics.NodeRules
import com.tugboat.android.toolkit.RegionHit

/**
 * Tap targets in the merged semantics tree (native SDK note 5, 6.2): the
 * nearest actionable node in the hit chain at the **down** position, else
 * the nearest kept node; their path, token, role, and alias.
 */
internal object NodeTargets {
    /** The target at ([x], [y]) in host pixels below [root], or [RegionHit.Miss]. */
    fun at(root: SemanticsNode, x: Float, y: Float): RegionHit {
        val chain = NodeHitTester.hit(root, x, y)
        val node = chain.lastOrNull(NodeRules::isActionable) ?: chain.lastOrNull(NodeRules::isKept) ?: return RegionHit.Miss
        return of(root, node) ?: RegionHit.Unreadable
    }

    /** [node]'s target, or null when it is no longer in [root]'s placed tree. */
    fun of(root: SemanticsNode, node: SemanticsNode): RegionHit.Target? = NodePaths.index(root)[node.id]?.let { of(node, it) }

    /** [node]'s target at a [path] already known ([NodePaths.index]). */
    fun of(node: SemanticsNode, path: NodePath): RegionHit.Target =
        RegionHit.Target(
            path = path.segments,
            widgetType = NodeRoles.token(node),
            role = NodeRoles.role(node),
            actions = NodeRoles.actions(node),
            enabled = NodeRoles.enabled(node),
            tag = NodeRules.alias(node),
            inListItem = path.inListItem,
            bounds = NodeBounds.bounds(node),
        )
}
