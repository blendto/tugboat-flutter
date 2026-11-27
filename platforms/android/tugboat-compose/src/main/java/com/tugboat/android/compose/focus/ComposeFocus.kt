package com.tugboat.android.compose.focus

import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import com.tugboat.android.compose.semantics.NodeRules
import com.tugboat.android.toolkit.RegionFocus

/**
 * Focus inside a Compose host (native SDK note 5): `TextInput` when a
 * focused node of the unmerged tree is editable, else `Other`; null when
 * the tree is unavailable.
 */
internal object ComposeFocus {
    fun of(root: SemanticsNode?): RegionFocus? {
        root ?: return null
        return if (focusedEditable(root)) RegionFocus.TextInput else RegionFocus.Other
    }

    private fun focusedEditable(node: SemanticsNode): Boolean {
        if (node.config.getOrNull(SemanticsProperties.Focused) == true && NodeRules.isEditable(node)) return true
        return node.children.any(::focusedEditable)
    }
}
