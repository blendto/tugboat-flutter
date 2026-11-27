package com.tugboat.android.views

import android.content.Context
import android.widget.CheckBox
import android.widget.CompoundButton
import android.widget.EditText
import android.widget.Switch
import androidx.appcompat.widget.SwitchCompat
import com.facebook.react.views.switchview.ReactSwitch
import com.tugboat.android.views.identity.ViewRoles
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/** Role and actions match the Flutter adapter's `widget_roles.dart`. */
@RunWith(RobolectricTestRunner::class)
class ViewRolesTest {
    private val context: Context = RuntimeEnvironment.getApplication()

    @Test
    fun switchesReportSwitchWhateverTheirClass() {
        assertEquals("switch", ViewRoles.role(Switch(context)))
        assertEquals("switch", ViewRoles.role(ReactSwitch(context)))
        assertEquals("switch", ViewRoles.role(SwitchCompat(context)))
        assertEquals("switch", ViewRoles.role(MyAppSwitch(context)))
        assertEquals("checkbox", ViewRoles.role(CheckBox(context)))
        assertEquals("checkbox", ViewRoles.role(object : CompoundButton(context) {}))
        // Same simple name, different package: not a switch.
        assertEquals("checkbox", ViewRoles.role(SwitchMaterial(context)))
    }

    @Test
    fun everySwitchClassNameIsKeptFromRenaming() {
        assertTrue("com.google.android.material.switchmaterial.SwitchMaterial" in ViewRoles.SWITCH_CLASSES)
        assertTrue("com.google.android.material.materialswitch.MaterialSwitch" in ViewRoles.SWITCH_CLASSES)
        val rules = File("consumer-rules.pro").readText()
        ViewRoles.SWITCH_CLASSES.forEach { assertTrue(it, rules.contains("-keepnames class $it")) }
    }

    @Test
    fun aTextFieldReportsOnlyInput() {
        val field = EditText(context).apply { setOnLongClickListener { true } }
        assertEquals(listOf("input"), ViewRoles.actions(field))
        assertEquals(emptyList<String>(), ViewRoles.actions(field.apply { isEnabled = false }))
    }

    @Test
    fun switchActionsStayTap() {
        assertEquals(listOf("tap"), ViewRoles.actions(ReactSwitch(context)))
    }

    class MyAppSwitch(context: Context) : SwitchCompat(context)

    // Named like the Material class but in another package: not matched.
    class SwitchMaterial(context: Context) : CompoundButton(context)
}
