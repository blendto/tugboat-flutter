package com.tugboat.android.views.overlay

import android.app.Activity
import android.os.Binder
import android.os.Bundle
import android.os.Looper
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

/**
 * The root classifier over real, attached roots: each window is added
 * through the activity's `WindowManager`, which gives it the token the
 * framework would (the activity's app token for dialogs, its decor's window
 * token for sub-windows).
 */
@RunWith(RobolectricTestRunner::class)
class OverlayWindowRootsTest {
    private val activity = Robolectric.buildActivity(BlankActivity::class.java).setup().get()
    private val decor = activity.window.decorView
    private val owners = OverlayWindowRoots.ownerTokens(activity.window)

    @Test
    fun theActivityWindowHasBothOwnerTokens() {
        assertTrue(decor.isShown)
        assertTrue(activity.window.attributes.token in owners)
        assertTrue(decor.windowToken in owners)
    }

    @Test
    fun activityDecorOnlyIsNotAnOverlay() {
        assertFalse(OverlayWindowRoots.hasOverlayRoot(listOf(decor), owners))
    }

    @Test
    fun applicationDialogRootIsAnOverlay() {
        val dialog = addWindow(WindowManager.LayoutParams.TYPE_APPLICATION)
        assertTrue(OverlayWindowRoots.hasOverlayRoot(listOf(decor, dialog), owners))
    }

    @Test
    fun nonFocusableApplicationWindowIsStillAnOverlay() {
        val dialog = addWindow(WindowManager.LayoutParams.TYPE_APPLICATION, WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE)
        assertTrue(OverlayWindowRoots.hasOverlayRoot(listOf(decor, dialog), owners))
    }

    @Test
    fun startingWindowRootIsNotAnOverlay() {
        val starting = addWindow(WindowManager.LayoutParams.TYPE_APPLICATION_STARTING)
        assertTrue("shown and owned: only its type excludes it", starting.isShown && starting.token() in owners)
        assertFalse(OverlayWindowRoots.hasOverlayRoot(listOf(decor, starting), owners))
    }

    @Test
    fun notShownRootIsNotAnOverlay() {
        val hidden = addWindow(WindowManager.LayoutParams.TYPE_APPLICATION)
        hidden.visibility = View.GONE
        assertTrue("attached and owned: only its visibility excludes it", hidden.isAttachedToWindow && hidden.token() in owners)
        assertFalse(OverlayWindowRoots.hasOverlayRoot(listOf(decor, hidden), owners))
    }

    @Test
    fun rootOfAnotherWindowIsNotAnOverlay() {
        val foreign = addWindow(WindowManager.LayoutParams.TYPE_APPLICATION, token = Binder())
        assertTrue("shown: only its token excludes it", foreign.isShown)
        assertFalse(OverlayWindowRoots.hasOverlayRoot(listOf(decor, foreign), owners))
    }

    @Test
    fun focusableSubWindowIsAnOverlay() {
        val popup = addWindow(WindowManager.LayoutParams.TYPE_APPLICATION_PANEL)
        assertTrue("a sub-window gets the decor's window token", popup.token() === decor.windowToken)
        assertTrue(OverlayWindowRoots.hasOverlayRoot(listOf(decor, popup), owners))
    }

    @Test
    fun nonFocusableSubWindowIsNotAnOverlay() {
        val handle = addWindow(WindowManager.LayoutParams.TYPE_APPLICATION_SUB_PANEL, WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE)
        assertTrue("shown and owned: only its focusability excludes it", handle.isShown && handle.token() in owners)
        assertFalse(OverlayWindowRoots.hasOverlayRoot(listOf(decor, handle), owners))
    }

    private fun addWindow(type: Int, flags: Int = 0, token: Binder? = null): View {
        val root = FrameLayout(activity)
        val params = WindowManager.LayoutParams(type, flags).also { it.token = token }
        activity.windowManager.addView(root, params)
        shadowOf(Looper.getMainLooper()).idle()
        return root
    }

    private fun View.token() = (layoutParams as WindowManager.LayoutParams).token

    class BlankActivity : Activity() {
        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            setContentView(FrameLayout(this))
        }
    }
}
