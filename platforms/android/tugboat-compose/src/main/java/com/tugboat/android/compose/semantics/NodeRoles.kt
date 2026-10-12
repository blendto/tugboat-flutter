package com.tugboat.android.compose.semantics

import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode

/**
 * Tokens and the shared anchor vocabulary for semantics nodes.
 *
 * - **Token** (native SDK note 6.2): the `Role` (`Button`, `Checkbox`,
 *   `Switch`, `RadioButton`, `Tab`, `Image`, `DropdownList`), then
 *   `TextField` for editable nodes, `Scrollable` for nodes with a scroll
 *   range, and `Node` otherwise.
 * - **Role and actions**: the vocabulary shared with the Flutter and Views
 *   adapters: roles `button`, `textField`, `checkbox`, `switch`, `radio`,
 *   `slider`, `dropdown`, `scrollable`; actions `tap`, `longPress`, `input`,
 *   `slide`, `scroll`.
 */
internal object NodeRoles {
    private val ROLE_TOKENS = mapOf(
        Role.Button to "Button",
        Role.Checkbox to "Checkbox",
        Role.Switch to "Switch",
        Role.RadioButton to "RadioButton",
        Role.Tab to "Tab",
        Role.Image to "Image",
        Role.DropdownList to "DropdownList",
    )

    fun token(node: SemanticsNode): String =
        NodeRules.role(node)?.let(ROLE_TOKENS::get)
            ?: when {
                NodeRules.isEditable(node) -> "TextField"
                NodeRules.isScrollable(node) -> "Scrollable"
                else -> "Node"
            }

    /** The anchor role, or null when [node] is not an actionable target. */
    fun role(node: SemanticsNode): String? =
        when {
            NodeRules.isEditable(node) -> "textField"
            SemanticsActions.SetProgress in node.config -> "slider"
            else -> roleOf(NodeRules.role(node)) ?: fallbackRole(node)
        }

    /** Sorted action names; empty when [node] is disabled. */
    fun actions(node: SemanticsNode): List<String> {
        if (NodeRules.isDisabled(node)) return emptyList()
        val config = node.config
        val actions = sortedSetOf<String>()
        if (SemanticsActions.OnClick in config) actions += "tap"
        if (SemanticsActions.OnLongClick in config) actions += "longPress"
        if (NodeRules.isEditable(node)) actions += "input"
        if (SemanticsActions.SetProgress in config) actions += "slide"
        if (NodeRules.isScrollable(node)) actions += "scroll"
        return actions.toList()
    }

    /** Whether [node] is enabled, for nodes with a role only. */
    fun enabled(node: SemanticsNode): Boolean? = if (role(node) != null) !NodeRules.isDisabled(node) else null

    private fun roleOf(role: Role?): String? =
        when (role) {
            Role.Checkbox -> "checkbox"
            Role.Switch -> "switch"
            Role.RadioButton -> "radio"
            Role.DropdownList -> "dropdown"
            else -> null
        }

    private fun fallbackRole(node: SemanticsNode): String? =
        when {
            NodeRules.isActionable(node) -> "button"
            NodeRules.isScrollable(node) -> "scrollable"
            else -> null
        }
}
