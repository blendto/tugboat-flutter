package com.tugboat.android.compose.semantics

import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import com.tugboat.android.compose.TugboatTagKey

/**
 * Which semantics nodes take part in identity and masks (native SDK note
 * 2.1 and 6.2). Read from a node's (merged or unmerged) configuration.
 *
 * - **Excluded** with their subtree: not placed, or zero size.
 * - **Kept**: actionable, editable, scrollable, maskable, or tagged nodes.
 *   Everything else collapses.
 * - **Maskable**: `Text` or `EditableText`, `Role.Image`, or a
 *   `ContentDescription` (image-like). Text never enters identity.
 */
internal object NodeRules {
    fun isExcluded(node: SemanticsNode): Boolean =
        !node.layoutInfo.isPlaced || node.size.width <= 0 || node.size.height <= 0

    fun isActionable(node: SemanticsNode): Boolean {
        val config = node.config
        return SemanticsActions.OnClick in config || SemanticsActions.OnLongClick in config ||
            SemanticsActions.SetProgress in config || SemanticsProperties.ToggleableState in config || isEditable(node)
    }

    fun isEditable(node: SemanticsNode): Boolean =
        SemanticsProperties.EditableText in node.config || SemanticsActions.SetText in node.config

    fun isScrollable(node: SemanticsNode): Boolean =
        SemanticsProperties.VerticalScrollAxisRange in node.config ||
            SemanticsProperties.HorizontalScrollAxisRange in node.config

    fun isMaskable(node: SemanticsNode): Boolean {
        val config = node.config
        return SemanticsProperties.Text in config || SemanticsProperties.EditableText in config ||
            SemanticsProperties.ContentDescription in config || role(node) == Role.Image
    }

    fun isKept(node: SemanticsNode): Boolean =
        isActionable(node) || isScrollable(node) || isMaskable(node) || alias(node) != null

    /** `Modifier.tugboatTag`, then `testTag`; null when neither is set. */
    fun alias(node: SemanticsNode): String? =
        node.config.getOrNull(TugboatTagKey)?.takeIf { it.isNotEmpty() }
            ?: node.config.getOrNull(SemanticsProperties.TestTag)?.takeIf { it.isNotEmpty() }

    fun role(node: SemanticsNode): Role? = node.config.getOrNull(SemanticsProperties.Role)

    fun isDisabled(node: SemanticsNode): Boolean = SemanticsProperties.Disabled in node.config
}
