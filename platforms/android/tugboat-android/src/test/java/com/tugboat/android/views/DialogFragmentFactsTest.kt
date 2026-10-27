package com.tugboat.android.views

import android.app.AlertDialog
import android.app.Dialog
import android.content.DialogInterface
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import androidx.fragment.app.DialogFragment
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import com.tugboat.android.views.callback.CallbackChain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.android.controller.ActivityController
import org.robolectric.annotation.Config

/**
 * `DialogFragment` dialogs get facts on every API level through fragment
 * lifecycle callbacks (below API 29 the only dialogs that do), with no
 * window-focus change: nested child managers, `onCreateDialog`-only
 * fragments (a framework `AlertDialog` included), and a stop and restart.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [26, 29])
class DialogFragmentFactsTest {
    private val harness = DialogHarness()
    private val adapter get() = harness.adapter

    @After
    fun stop() = harness.stop()

    @Test
    fun aTapInADialogFragmentViewUsesTheFragmentRoute() {
        val activity = host().get()
        val fragment = ButtonDialogFragment()
        fragment.show(activity.supportFragmentManager, "confirm")
        idleMain()
        assertEquals(1, adapter.dialogSessionCount(activity))
        harness.drainFacts()

        tapThrough(fragment.requireDialog().window!!, fragment.button)

        val anchor = harness.pointerUps().single().tapAnchor()
        assertEquals("confirm", anchor.getJSONObject("fingerprintParts").getString("routeKey"))
        assertEquals("Button#button3", anchor.getString("canonicalPath"))
    }

    @Test
    fun aDialogFragmentShownFromAChildManagerCounts() {
        val activity = host().get()
        val parent = Fragment()
        activity.supportFragmentManager.beginTransaction().add(android.R.id.content, parent, "parent").commitNow()
        val fragment = ButtonDialogFragment()
        fragment.show(parent.childFragmentManager, "nested")
        idleMain()
        assertEquals(1, adapter.dialogSessionCount(activity))
        harness.drainFacts()

        tapThrough(fragment.requireDialog().window!!, fragment.button)
        assertEquals(1, harness.pointerUps().size)
    }

    @Test
    fun anOnCreateDialogOnlyFragmentCountsEvenWithAFrameworkDialog() {
        val activity = host().get()
        val fragment = AlertOnlyFragment()
        fragment.show(activity.supportFragmentManager, "alert")
        idleMain()
        assertEquals(1, adapter.dialogSessionCount(activity))
        harness.drainFacts()

        val dialog = fragment.requireDialog() as AlertDialog
        tapThrough(dialog.window!!, dialog.getButton(DialogInterface.BUTTON_POSITIVE))

        val anchor = harness.pointerUps().single().tapAnchor()
        assertTrue(anchor.getString("canonicalPath"), anchor.getString("canonicalPath").endsWith("Button#button1"))
        assertEquals(FragmentActivity::class.java.name, anchor.getJSONObject("fingerprintParts").getString("routeKey"))
    }

    @Test
    fun aStoppedDialogFragmentDetachesAndItsRestartAttachesAgain() {
        val controller = host()
        val activity = controller.get()
        val fragment = ButtonDialogFragment()
        fragment.show(activity.supportFragmentManager, "confirm")
        idleMain()
        val window = fragment.requireDialog().window!!

        controller.pause().stop()
        idleMain()
        assertEquals(0, adapter.dialogSessionCount(activity))
        assertEquals(0, CallbackChain.countTugboat(window.callback))

        controller.restart().start().resume()
        idleMain()
        assertEquals(1, adapter.dialogSessionCount(activity))
        harness.drainFacts()
        tapThrough(window, fragment.button)
        assertEquals(1, harness.pointerUps().size)
    }

    @Test
    fun aDismissedDialogFragmentEndsItsSession() {
        val activity = host().get()
        val fragment = ButtonDialogFragment()
        fragment.show(activity.supportFragmentManager, "confirm")
        idleMain()
        val window = fragment.requireDialog().window!!

        fragment.dismissNow()
        idleMain()
        assertEquals(0, adapter.dialogSessionCount(activity))
        assertEquals(0, CallbackChain.countTugboat(window.callback))
    }

    @Test
    fun aSessionStartedWithADialogFragmentUpAdoptsIt() {
        val activity = host().get()
        val fragment = ButtonDialogFragment()
        fragment.show(activity.supportFragmentManager, "confirm")
        idleMain()
        adapter.stop()

        adapter.start()
        assertEquals(1, adapter.dialogSessionCount(activity))
        harness.drainFacts()
        tapThrough(fragment.requireDialog().window!!, fragment.button)
        assertEquals(1, harness.pointerUps().size)
    }

    private fun host(): ActivityController<FragmentActivity> =
        Robolectric.buildActivity(FragmentActivity::class.java).setup().also { idleMain() }

    /** A dialog fragment with a view: the default `ComponentDialog` shows it. */
    class ButtonDialogFragment : DialogFragment() {
        lateinit var button: Button

        override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View {
            button = Button(inflater.context).apply { id = android.R.id.button3 }
            return FrameLayout(inflater.context).apply { addView(button, FrameLayout.LayoutParams(300, 200)) }
        }
    }

    /** No view: only `onCreateDialog`, here a framework `AlertDialog`. */
    class AlertOnlyFragment : DialogFragment() {
        override fun onCreateDialog(savedInstanceState: Bundle?): Dialog =
            AlertDialog.Builder(requireContext()).setMessage("Delete?").setPositiveButton("OK", null).create()
    }
}
