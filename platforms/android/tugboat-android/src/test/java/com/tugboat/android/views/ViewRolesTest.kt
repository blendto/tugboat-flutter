package com.tugboat.android.views

import android.content.Context
import android.widget.CheckBox
import android.widget.CompoundButton
import android.widget.EditText
import android.widget.Switch
import com.tugboat.android.views.identity.ViewRoles
import org.junit.Assert.assertEquals
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
        assertEquals("switch", ViewRoles.role(SwitchMaterial(context)))
        assertEquals("switch", ViewRoles.role(MaterialSwitch(context)))
        assertEquals("switch", ViewRoles.role(MyAppSwitch(context)))
        assertEquals("checkbox", ViewRoles.role(CheckBox(context)))
        assertEquals("checkbox", ViewRoles.role(object : CompoundButton(context) {}))
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

    // Stand-ins named like the real classes, which are not on the test classpath.
    class ReactSwitch(context: Context) : CompoundButton(context)

    open class SwitchCompat(context: Context) : CompoundButton(context)

    class SwitchMaterial(context: Context) : SwitchCompat(context)

    class MaterialSwitch(context: Context) : CompoundButton(context)

    class MyAppSwitch(context: Context) : SwitchCompat(context)
}
