package com.tugboat.android.views.identity

import android.view.View
import com.tugboat.android.views.scroll.Scrollables
import android.widget.AbsSeekBar
import android.widget.CheckBox
import android.widget.CompoundButton
import android.widget.RadioButton
import android.widget.Spinner
import android.widget.Switch
import android.widget.ToggleButton

/**
 * The anchor `role` and `actions` vocabulary, shared with the Flutter
 * adapter: `button`, `textField`, `checkbox`, `switch`, `radio`, `slider`,
 * `dropdown`, `scrollable`; actions `tap`, `longPress`, `input`, `slide`,
 * `scroll`. Platform classes only, so app subclasses map the same way.
 */
internal object ViewRoles {
    /** The role of [view], or null when it is not an actionable target. */
    fun role(view: View): String? =
        when {
            ViewRules.isEditable(view) -> "textField"
            view is AbsSeekBar -> "slider"
            view is Spinner -> "dropdown"
            view is CompoundButton -> compoundRole(view)
            ViewRules.isActionable(view) -> "button"
            Scrollables.isScrollable(view) -> "scrollable"
            else -> null
        }

    /** Sorted action names; empty when [view] is disabled. */
    fun actions(view: View): List<String> {
        if (!view.isEnabled) return emptyList()
        val actions = sortedSetOf<String>()
        if (view.isClickable || view is CompoundButton) actions += "tap"
        if (view.isLongClickable) actions += "longPress"
        if (ViewRules.isEditable(view)) actions += "input"
        if (view is AbsSeekBar) actions += "slide"
        if (Scrollables.isScrollable(view)) actions += "scroll"
        return actions.toList()
    }

    private fun compoundRole(view: CompoundButton): String =
        when (view) {
            is RadioButton -> "radio"
            is CheckBox -> "checkbox"
            is Switch, is ToggleButton -> "switch"
            else -> "checkbox"
        }
}
