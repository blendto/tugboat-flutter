package com.tugboat.android.compose.identity

import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull

/** A list item's path segment; [indexed] when it carries a stable index. */
internal class ListItem(val segment: String, val indexed: Boolean)

/**
 * List items (native SDK note 6.2): a direct child of a node with
 * `CollectionInfo` (`LazyColumn`, `LazyRow`, grids) is an item.
 *
 * - With `CollectionItemInfo`: `[item:<row>]` (the column in a one-row
 *   collection), a stable index.
 * - Without it (lazy layouts set none): `[item]`. Its traversal order on
 *   screen changes as the list scrolls, so it is not identity; every such
 *   row shares one structural fingerprint at `low` confidence. Apps make rows
 *   distinct with `Modifier.semantics { collectionItemInfo = ... }` or a
 *   `tugboatTag`.
 */
internal object ListItems {
    /** [child]'s item segment when [parent] is a collection, else null. */
    fun of(parent: SemanticsNode, child: SemanticsNode): ListItem? {
        val collection = parent.config.getOrNull(SemanticsProperties.CollectionInfo) ?: return null
        val info = child.config.getOrNull(SemanticsProperties.CollectionItemInfo) ?: return ListItem("[item]", indexed = false)
        val index = if (collection.rowCount == 1 && collection.columnCount != 1) info.columnIndex else info.rowIndex
        return ListItem("[item:$index]", indexed = true)
    }
}
