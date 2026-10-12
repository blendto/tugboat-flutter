package com.tugboat.android.compose.identity

import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import com.tugboat.android.compose.semantics.NodeRules

/**
 * List items (native SDK note 6.2): a direct child of a node with
 * `CollectionInfo` (`LazyColumn`, `LazyRow`, grids) is an item. Its index is
 * its `CollectionItemInfo` (the row, or the column in a one-row
 * collection), else its traversal order among the collection's children:
 * top to bottom, then left to right.
 *
 * Lazy layouts set no `CollectionItemInfo` on their items, so the
 * traversal fallback counts from the first item on screen: a known gap that
 * apps close with `Modifier.semantics { collectionItemInfo = ... }` or a
 * `tugboatTag`.
 */
internal object ListItems {
    /** [child]'s item index when [parent] is a collection, else null. */
    fun index(parent: SemanticsNode, child: SemanticsNode): Int? {
        val collection = parent.config.getOrNull(SemanticsProperties.CollectionInfo) ?: return null
        val info = child.config.getOrNull(SemanticsProperties.CollectionItemInfo)
        if (info != null) return if (collection.rowCount == 1 && collection.columnCount != 1) info.columnIndex else info.rowIndex
        return traversalOrder(parent).indexOfFirst { it.id == child.id }.takeIf { it >= 0 }
    }

    private fun traversalOrder(parent: SemanticsNode): List<SemanticsNode> =
        parent.children
            .filterNot(NodeRules::isExcluded)
            .sortedWith(compareBy({ it.boundsInRoot.top }, { it.boundsInRoot.left }))
}
