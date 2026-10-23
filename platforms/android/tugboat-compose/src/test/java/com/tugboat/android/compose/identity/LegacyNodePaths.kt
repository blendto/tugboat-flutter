package com.tugboat.android.compose.identity

import androidx.compose.ui.semantics.SemanticsNode
import com.tugboat.android.compose.semantics.NodeRoles
import com.tugboat.android.compose.semantics.NodeRules

/**
 * The tap path before the single index (`NodePaths.build`, deleted in round 4
 * of PR #116), kept verbatim as a test oracle: [NodePaths.index] must give
 * every node this path on every tested Compose UI version.
 */
internal object LegacyNodePaths {
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
