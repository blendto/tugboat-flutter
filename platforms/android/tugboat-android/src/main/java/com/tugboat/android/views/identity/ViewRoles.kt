package com.tugboat.android.views.identity

import android.view.View
import android.widget.AbsSeekBar
import android.widget.CheckBox
import android.widget.CompoundButton
import android.widget.RadioButton
import android.widget.Spinner
import android.widget.Switch
import android.widget.ToggleButton
import com.tugboat.android.views.scroll.Scrollables

/**
 * The anchor `role` and `actions` vocabulary, shared with the Flutter
 * adapter: `button`, `textField`, `checkbox`, `switch`, `radio`, `slider`,
 * `dropdown`, `scrollable`; actions `tap`, `longPress`, `input`, `slide`,
 * `scroll`. Platform classes, plus the four switch classes of React Native and
 * AndroidX matched by name, so app subclasses map the same way.
 */
internal object ViewRoles {
    /**
     * `ReactSwitch`, `SwitchCompat`, `SwitchMaterial` and `MaterialSwitch` are
     * not `android.widget.Switch`: the class chain is matched by fully
     * qualified name, so no dependency is needed. `consumer-rules.pro` keeps
     * these names.
     */
    internal val SWITCH_CLASSES =
        setOf(
            "com.facebook.react.views.switchview.ReactSwitch",
            "androidx.appcompat.widget.SwitchCompat",
            "com.google.android.material.switchmaterial.SwitchMaterial",
            "com.google.android.material.materialswitch.MaterialSwitch",
        )

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
        if (ViewRules.isEditable(view)) {
            // A text field reports only input, as in the Flutter adapter.
            actions += "input"
        } else {
            if (view.isClickable || view is CompoundButton) actions += "tap"
            if (view.isLongClickable) actions += "longPress"
        }
        if (view is AbsSeekBar) actions += "slide"
        if (Scrollables.isScrollable(view)) actions += "scroll"
        return actions.toList()
    }

    private fun compoundRole(view: CompoundButton): String =
        when (view) {
            is RadioButton -> "radio"
            is CheckBox -> "checkbox"
            is Switch, is ToggleButton -> "switch"
            else -> if (isSwitchByName(view.javaClass)) "switch" else "checkbox"
        }

    private fun isSwitchByName(type: Class<*>): Boolean {
        var current: Class<*>? = type
        while (current != null && current != CompoundButton::class.java) {
            if (current.name in SWITCH_CLASSES) return true
            current = current.superclass
        }
        return false
    }
}
