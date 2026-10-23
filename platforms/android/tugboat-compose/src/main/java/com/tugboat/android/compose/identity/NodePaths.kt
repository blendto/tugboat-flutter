package com.tugboat.android.compose.identity

import androidx.compose.ui.semantics.SemanticsNode
import com.tugboat.android.compose.semantics.NodeRoles
import com.tugboat.android.compose.semantics.NodeRules

/** A node's canonical path segments below the Compose root; [inListItem] only for a stably indexed item. */
internal class NodePath(val segments: List<String>, val inListItem: Boolean)

/**
 * Canonical paths in the merged semantics tree (native SDK note 6, 6.2),
 * built like the Views paths:
 *
 * - A segment is the node's token ([NodeRoles.token]) plus `#<ordinal>`.
 * - Only kept nodes ([NodeRules.isKept]) get segments; the rest collapse.
 * - Ordinals count same-token siblings after filtering: the kept nodes (and
 *   list items) whose nearest kept ancestor is the same, in paint order.
 * - A list item adds `[item:<index>]`, or `[item]` without a stable index
 *   ([ListItems]), and scopes the ordinals of everything inside it.
 *
 * The Compose root is not part of the path; the Views adapter prefixes the
 * host's own path. Aliases and text never enter it.
 */
internal object NodePaths {
    /** Every node id below [root] to its path, built in one top-down walk. */
    fun index(root: SemanticsNode): Map<Int, NodePath> {
        val paths = HashMap<Int, NodePath>()
        for (child in root.children) {
            indexWalk(root, child, root, ArrayList(), false, paths)
        }
        return paths
    }

    /** [target]'s path below [root], or null when [target] is not in [root]'s tree. */
    fun build(root: SemanticsNode, target: SemanticsNode): NodePath? {
        val chain = chainTo(root, target.id) ?: return null
        val segments = ArrayList<String>()
        var scope = root
        var parent = root
        var inListItem = false
        for (node in chain) {
            val item = ListItems.of(parent, node)
            parent = node
            if (item != null) {
                segments += item.segment
                inListItem = inListItem || item.indexed
                scope = node
                if (NodeRules.isKept(node)) segments += "${NodeRoles.token(node)}#0"
                continue
            }
            if (!NodeRules.isKept(node)) continue
            val token = NodeRoles.token(node)
            segments += "$token#${ordinal(scope, node, token)}"
            scope = node
        }
        return NodePath(segments, inListItem)
    }

    private fun indexWalk(
        root: SemanticsNode,
        node: SemanticsNode,
        scope: SemanticsNode,
        segments: ArrayList<String>,
        inListItem: Boolean,
        paths: MutableMap<Int, NodePath>,
    ) {
        val item = ListItems.of(scope, node)
        val childSegments = ArrayList(segments)
        var childScope = scope
        var childInListItem = inListItem
        if (item != null) {
            childSegments += item.segment
            childInListItem = childInListItem || item.indexed
            childScope = node
            if (NodeRules.isKept(node)) childSegments += "${NodeRoles.token(node)}#0"
        } else if (NodeRules.isKept(node)) {
            val token = NodeRoles.token(node)
            childSegments += "$token#${ordinal(scope, node, token)}"
            childScope = node
        }
        paths[node.id] = NodePath(childSegments.toList(), childInListItem)
        for (child in node.children) {
            indexWalk(root, child, childScope, childSegments, childInListItem, paths)
        }
    }

    /** The nodes strictly below [root] down to the node with [id], top first. */
    private fun chainTo(root: SemanticsNode, id: Int): List<SemanticsNode>? {
        for (child in root.children) {
            if (child.id == id) return listOf(child)
            chainTo(child, id)?.let { return listOf(child) + it }
        }
        return null
    }

    private fun ordinal(scope: SemanticsNode, node: SemanticsNode, token: String): Int {
        var ordinal = 0
        for ((parent, sibling) in filteredChildren(scope)) {
            if (sibling.id == node.id) return ordinal
            if (ListItems.of(parent, sibling) == null && NodeRoles.token(sibling) == token) ordinal++
        }
        return ordinal
    }

    /** The kept nodes and list items whose nearest scope is [scope], with their parents, in paint order. */
    private fun filteredChildren(scope: SemanticsNode): List<Pair<SemanticsNode, SemanticsNode>> {
        val out = ArrayList<Pair<SemanticsNode, SemanticsNode>>()
        collect(scope, out)
        return out
    }

    private fun collect(parent: SemanticsNode, out: MutableList<Pair<SemanticsNode, SemanticsNode>>) {
        for (child in parent.children) {
            when {
                NodeRules.isExcluded(child) -> Unit
                ListItems.of(parent, child) != null || NodeRules.isKept(child) -> out += parent to child
                else -> collect(child, out)
            }
        }
    }
}
