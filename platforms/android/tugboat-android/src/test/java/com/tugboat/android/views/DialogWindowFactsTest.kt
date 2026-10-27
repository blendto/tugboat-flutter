package com.tugboat.android.views

import android.content.DialogInterface
import android.os.Bundle
import android.view.View
import android.view.Window
import android.view.inspector.WindowInspector
import android.widget.EditText
import android.widget.FrameLayout
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import com.tugboat.android.toolkit.MaskCoverageReason
import com.tugboat.android.views.callback.CallbackChain
import com.tugboat.android.views.dialog.DialogWindowLookup
import com.tugboat.android.views.overlay.OverlayWindowRoots
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.lang.reflect.Proxy

/**
 * Facts from dialog windows found through `WindowInspector` (API 29+): an
 * AppCompat `AlertDialog` (a `ComponentDialog`) gets pointer, key and focus
 * facts once the activity window loses focus; a framework `AlertDialog`
 * shown without a fragment does not (the documented gap) and its frames
 * still carry `overlayWindow`. Density 2 (xhdpi), so dp and px differ.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29], qualifiers = "xhdpi")
class DialogWindowFactsTest {
    private val harness = DialogHarness()
    private val adapter get() = harness.adapter

    @After
    fun stop() = harness.stop()

    @Test
    fun anAppCompatAlertDialogTapIsOnePointerUpWithTheButtonAnchorInActivityDp() {
        val activity = host()
        val dialog = appCompatDialog(activity)
        activity.windowFocus(false)
        assertEquals(1, adapter.dialogSessionCount(activity))
        harness.drainFacts()

        val button = dialog.getButton(DialogInterface.BUTTON_POSITIVE)
        val (x, y) = centerInWindow(button)
        tapThrough(dialog.window!!, x, y)

        val up = harness.pointerUps().single()
        val anchor = up.tapAnchor()
        assertTrue(anchor.getString("canonicalPath"), anchor.getString("canonicalPath").endsWith("Button#button1"))
        assertEquals(Host::class.java.name, anchor.getJSONObject("fingerprintParts").getString("routeKey"))
        assertEquals("activity dp", x / 2.0, up.getDouble("x"), 1e-6)
        assertEquals("activity dp", y / 2.0, up.getDouble("y"), 1e-6)
    }

    @Test
    fun dialogPositionsAreReportedInActivitySpaceAndHitTestedInTheDialogs() {
        val activity = host()
        val dialog = appCompatDialog(activity)
        harness.locations[activity.window.decorView] = 0 to 48
        harness.locations[dialog.window!!.decorView] = 60 to 700
        activity.windowFocus(false)
        harness.drainFacts()

        val (x, y) = centerInWindow(dialog.getButton(DialogInterface.BUTTON_POSITIVE))
        tapThrough(dialog.window!!, x, y)

        val up = harness.pointerUps().single()
        assertEquals((x + 60) / 2.0, up.getDouble("x"), 1e-6)
        assertEquals((y + 652) / 2.0, up.getDouble("y"), 1e-6)
        assertTrue("hit-tested without the offset", up.tapAnchor().getString("canonicalPath").endsWith("Button#button1"))
    }

    @Test
    fun aDismissedDialogIsUnwrappedAndSilent() {
        val activity = host()
        val dialog = appCompatDialog(activity)
        val window = dialog.window!!
        activity.windowFocus(false)
        assertEquals(1, CallbackChain.countTugboat(window.callback))

        dialog.dismiss()
        idleMain()
        harness.drainFacts()

        assertEquals(0, adapter.dialogSessionCount(activity))
        assertEquals(0, CallbackChain.countTugboat(window.callback))
        tapThrough(window, 10f, 10f)
        assertTrue(harness.drainFacts().isEmpty())
    }

    @Test
    fun backOnADialogIsSystemInputBackAndClosesIt() {
        val activity = host()
        val dialog = appCompatDialog(activity)
        activity.windowFocus(false)
        harness.drainFacts()

        backThrough(dialog.window!!)
        idleMain()

        val inputs = harness.drainFacts().filter { it.first == "systemInput" }.map { it.second.getString("input") }
        assertEquals(listOf("back"), inputs)
        assertFalse(dialog.isShowing)
    }

    @Test
    fun aDialogTextFieldReportsTextInputOnceItsWindowHasFocusAndTheActivityTakesOverAgain() {
        val activity = host()
        val field = EditText(activity)
        val dialog = AlertDialog.Builder(activity).setView(field).setPositiveButton("OK", null).show()
        idleMain()
        activity.windowFocus(false)
        harness.drainFacts()

        dialog.window!!.callback.onWindowFocusChanged(true)
        field.requestFocus()
        assertEquals(listOf("text_input"), focusKinds())

        dialog.dismiss()
        activity.windowFocus(true)
        val back = focusKinds()
        assertEquals(1, back.size)
        assertTrue(back.single(), back.single() in setOf("none", "other"))
    }

    @Test
    fun aFrameworkAlertDialogIsSeenButGetsNoSessionAndStillFlagsTheFrame() {
        val activity = host()
        val dialog = android.app.AlertDialog.Builder(activity).setMessage("framework").setPositiveButton("OK", null).show()
        idleMain()
        val tokens = OverlayWindowRoots.ownerTokens(activity.window)
        val root = WindowInspector.getGlobalWindowViews().single { OverlayWindowRoots.isOwnedDialogRoot(it, tokens) }
        assertNull("no public way back to its Window", DialogWindowLookup.windowOf(root))

        activity.windowFocus(false)
        harness.drainFacts()
        assertEquals(0, adapter.dialogSessionCount(activity))
        tapThrough(dialog.window!!, dialog.getButton(DialogInterface.BUTTON_POSITIVE))
        assertTrue(harness.drainFacts().none { it.first == "input.pointer" })
        assertTrue(MaskCoverageReason.OverlayWindow in adapter.masks(activity.window).coverage.reasons)
    }

    @Test
    fun aSessionStartedWithADialogUpAdoptsIt() {
        val activity = host()
        val dialog = appCompatDialog(activity)
        activity.windowFocus(false)
        adapter.stop()
        assertEquals(0, adapter.dialogSessionCount(activity))

        adapter.start()
        assertEquals("adopted without any focus change", 1, adapter.dialogSessionCount(activity))
        harness.drainFacts()
        tapThrough(dialog.window!!, dialog.getButton(DialogInterface.BUTTON_POSITIVE))
        assertEquals(1, harness.pointerUps().size)
    }

    @Test
    fun aForeignWrapperOnTheDialogCallbackKeepsFactsSingleAndOursInertAfterDismiss() {
        val activity = host()
        val dialog = appCompatDialog(activity)
        val window = dialog.window!!
        val below = CountingWrapper(window.callback)
        window.callback = below.proxy
        activity.windowFocus(false)
        val above = CountingWrapper(window.callback)
        window.callback = above.proxy
        assertEquals(1, CallbackChain.countTugboat(window.callback))
        harness.drainFacts()

        val (x, y) = centerInWindow(dialog.getButton(DialogInterface.BUTTON_NEGATIVE))
        tapThrough(window, x, y)
        assertEquals(1, harness.pointerUps().size)
        assertEquals("each wrapper forwards each event once", listOf(2, 2), listOf(above.touches, below.touches))

        dialog.dismiss()
        idleMain()
        assertEquals("below a foreign wrapper ours stays", 1, CallbackChain.countTugboat(window.callback))
        tapThrough(window, x, y)
        assertTrue("and is inert", harness.drainFacts().isEmpty())
    }

    @Test
    fun aDismissedDialogSessionIsNotRetained() {
        val activity = host()
        appCompatDialog(activity).also { activity.windowFocus(false) }.dismiss()
        idleMain()
        repeat(GC_ROUNDS) {
            if (adapter.dialogSessionCount(activity) == 0) return@repeat
            System.gc()
            System.runFinalization()
        }
        assertEquals(0, adapter.dialogSessionCount(activity))
    }

    private fun focusKinds(): List<String> =
        harness.drainFacts().filter { it.first == "focus" }.map { it.second.getString("kind") }

    private fun host(): Host = Robolectric.buildActivity(Host::class.java).setup().get().also { idleMain() }

    private fun appCompatDialog(activity: Host): AlertDialog =
        AlertDialog.Builder(activity)
            .setMessage("Delete?")
            .setPositiveButton("OK", null)
            .setNegativeButton("Cancel", null)
            .show()
            .also { idleMain() }

    /** A foreign SDK's wrapper (a forwarding proxy) that counts touches. */
    private class CountingWrapper(inner: Window.Callback) {
        var touches = 0
        val proxy: Window.Callback =
            Proxy.newProxyInstance(Window.Callback::class.java.classLoader, arrayOf(Window.Callback::class.java)) { _, method, args ->
                if (method.name == "dispatchTouchEvent") touches++
                method.invoke(inner, *(args ?: emptyArray()))
            } as Window.Callback
    }

    class Host : AppCompatActivity() {
        override fun onCreate(savedInstanceState: Bundle?) {
            setTheme(androidx.appcompat.R.style.Theme_AppCompat_Light_NoActionBar)
            super.onCreate(savedInstanceState)
            setContentView(FrameLayout(this).apply { addView(View(context), FrameLayout.LayoutParams(10, 10)) })
        }
    }

    private companion object {
        const val GC_ROUNDS = 20
    }
}
