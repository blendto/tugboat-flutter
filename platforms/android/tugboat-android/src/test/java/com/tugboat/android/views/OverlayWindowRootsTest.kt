package com.tugboat.android.views

import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import com.tugboat.android.views.overlay.OverlayWindowRoots
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class OverlayWindowRootsTest {
    @Test
    fun activityDecorOnlyIsNotAnOverlay() {
        val decor = FrameLayout(context)
        assertFalse(OverlayWindowRoots.hasOverlayRoot(listOf(decor), decor))
    }

    @Test
    fun applicationDialogRootIsAnOverlay() {
        val decor = FrameLayout(context)
        val dialogRoot = shownOverlayRoot(WindowManager.LayoutParams.TYPE_APPLICATION)
        assertTrue(OverlayWindowRoots.isOverlayRoot(dialogRoot))
        assertTrue(OverlayWindowRoots.hasOverlayRoot(listOf(decor, dialogRoot), decor))
    }

    @Test
    fun startingWindowRootIsNotAnOverlay() {
        val decor = FrameLayout(context)
        val starting = overlayRoot(WindowManager.LayoutParams.TYPE_APPLICATION_STARTING)
        assertFalse(OverlayWindowRoots.hasOverlayRoot(listOf(decor, starting), decor))
    }

    @Test
    fun notShownRootIsNotAnOverlay() {
        val decor = FrameLayout(context)
        val hidden = overlayRoot(WindowManager.LayoutParams.TYPE_APPLICATION).apply { visibility = View.GONE }
        assertFalse(OverlayWindowRoots.hasOverlayRoot(listOf(decor, hidden), decor))
    }

    private fun overlayRoot(type: Int): View =
        FrameLayout(context).apply {
            layoutParams = WindowManager.LayoutParams(type)
            visibility = View.VISIBLE
        }

    private fun shownOverlayRoot(type: Int): View =
        object : FrameLayout(context) {
            override fun isShown(): Boolean = true
        }.apply {
            layoutParams = WindowManager.LayoutParams(type)
            visibility = View.VISIBLE
        }
}
