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
    /**
     * Every node id below [root] to the path [build] gives it, in one
     * top-down walk: each node's children are read once, and ordinals are
     * counted per scope as the walk meets them (paint order). Excluded nodes
     * ([NodeRules.isExcluded]) and their subtrees have no entry.
     */
    fun index(root: SemanticsNode): Map<Int, NodePath> {
        val index = PathIndex()
        for (child in root.children) index.walk(child, parent = root, scope = root, emptyList(), inListItem = false)
        return index.paths
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

    /** [index]'s walk state: the paths so far and, per scope node id, the next ordinal of each token. */
    private class PathIndex {
        val paths = HashMap<Int, NodePath>()
        private val ordinals = HashMap<Int, HashMap<String, Int>>()

        fun walk(node: SemanticsNode, parent: SemanticsNode, scope: SemanticsNode, segments: List<String>, inListItem: Boolean) {
            if (NodeRules.isExcluded(node)) return
            val item = ListItems.of(parent, node)
            var childSegments = segments
            var childScope = scope
            var childInListItem = inListItem
            if (item != null) {
                childSegments = segments + item.segment
                if (NodeRules.isKept(node)) childSegments = childSegments + "${NodeRoles.token(node)}#0"
                childInListItem = inListItem || item.indexed
                childScope = node
            } else if (NodeRules.isKept(node)) {
                val token = NodeRoles.token(node)
                childSegments = segments + "$token#${nextOrdinal(scope, token)}"
                childScope = node
            }
            paths[node.id] = NodePath(childSegments, childInListItem)
            for (child in node.children) walk(child, node, childScope, childSegments, childInListItem)
        }

        private fun nextOrdinal(scope: SemanticsNode, token: String): Int {
            val counts = ordinals.getOrPut(scope.id) { HashMap() }
            val ordinal = counts[token] ?: 0
            counts[token] = ordinal + 1
            return ordinal
        }
    }
}
