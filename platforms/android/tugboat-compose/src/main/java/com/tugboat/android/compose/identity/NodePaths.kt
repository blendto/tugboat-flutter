package com.tugboat.android.compose.identity

import androidx.compose.ui.semantics.SemanticsNode
import com.tugboat.android.compose.semantics.NodeRoles
import com.tugboat.android.compose.semantics.NodeRules

/** A node's canonical path segments below the Compose root. */
internal class NodePath(val segments: List<String>, val inListItem: Boolean)

/**
 * Canonical paths in the merged semantics tree (native SDK note 6, 6.2),
 * built like the Views paths:
 *
 * - A segment is the node's token ([NodeRoles.token]) plus `#<ordinal>`.
 * - Only kept nodes ([NodeRules.isKept]) get segments; the rest collapse.
 * - Ordinals count same-token siblings after filtering: the kept nodes (and
 *   list items) whose nearest kept ancestor is the same, in paint order.
 * - A list item adds `[item:<index>]` ([ListItems]) and scopes the ordinals
 *   of everything inside it.
 *
 * The Compose root is not part of the path; the Views adapter prefixes the
 * host's own path. Aliases and text never enter it.
 */
internal object NodePaths {
    /** [target]'s path below [root], or null when [target] is not in [root]'s tree. */
    fun build(root: SemanticsNode, target: SemanticsNode): NodePath? {
        val chain = chainTo(root, target.id) ?: return null
        val segments = ArrayList<String>()
        var scope = root
        var parent = root
        var inListItem = false
        for (node in chain) {
            val item = ListItems.index(parent, node)
            parent = node
            if (item != null) {
                segments += "[item:$item]"
                inListItem = true
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
            if (ListItems.index(parent, sibling) == null && NodeRoles.token(sibling) == token) ordinal++
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
                ListItems.index(parent, child) != null || NodeRules.isKept(child) -> out += parent to child
                else -> collect(child, out)
            }
        }
    }
}
