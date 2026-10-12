package com.tugboat.android.views

import android.app.Activity
import android.text.InputType
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.VideoView
import androidx.compose.ui.platform.ComposeView
import com.tugboat.android.views.identity.ViewTags
import com.tugboat.android.views.mask.MaskRect
import com.tugboat.android.views.mask.MaskSource
import com.tugboat.android.views.mask.WindowMasks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

/** Mask sources per native SDK note 2.1 (Views row), normalized to the decor view. */
@RunWith(RobolectricTestRunner::class)
class WindowMasksTest {
    @Test
    fun textAndMediaAreMaskedAtTheirBounds() {
        val root = column(
            TextView(context) to 100,
            Button(context) to 100,
            EditText(context).apply { inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD } to 100,
            ImageView(context) to 100,
            View(context) to 100, // plain view: not masked
        )
        layOut(root, 1000, 1000)
        val result = WindowMasks.compute(root)
        assertFalse(result.failClosed)
        assertRects(listOf(rect(0.0, 0.0), rect(0.0, 0.1), rect(0.0, 0.2), rect(0.0, 0.3)), result.rects)
    }

    @Test
    fun opaqueContentIsMaskedWholeWithoutLookingInside() {
        val root = column(SurfaceView(context) to 100, TextureView(context) to 100, VideoView(context) to 100)
        layOut(root, 1000, 1000)
        assertRects(listOf(rect(0.0, 0.0), rect(0.0, 0.1), rect(0.0, 0.2)), WindowMasks.compute(root).rects)
    }

    @Test
    fun everyViewsRowSourceIsClassified() {
        // Robolectric's WebView shadow never lays out, so WebView is checked by
        // classification; its bounds follow the same path as SurfaceView's.
        assertEquals(MaskSource.FailClosed, WindowMasks.sourceOf(WebView(context)))
        assertEquals(MaskSource.FailClosed, WindowMasks.sourceOf(SurfaceView(context)))
        assertEquals(MaskSource.FailClosed, WindowMasks.sourceOf(TextureView(context)))
        assertEquals(MaskSource.FailClosed, WindowMasks.sourceOf(VideoView(context)))
        assertEquals(MaskSource.Text, WindowMasks.sourceOf(TextView(context)))
        assertEquals(MaskSource.Text, WindowMasks.sourceOf(EditText(context)))
        assertEquals(MaskSource.Text, WindowMasks.sourceOf(Button(context)))
        assertEquals(MaskSource.Media, WindowMasks.sourceOf(ImageView(context)))
        assertEquals(null, WindowMasks.sourceOf(FrameLayout(context)))
    }

    @Test
    fun composeHostedInViewsIsFailClosedAndNotWalked() {
        val compose = ComposeView(context).apply { addView(TextView(context), FrameLayout.LayoutParams(100, 50)) }
        val root = column(compose to 300)
        layOut(root, 1000, 1000)
        assertEquals(MaskSource.FailClosed, WindowMasks.sourceOf(compose))
        assertRects(listOf(MaskRect(0.0, 0.0, 1.0, 0.3)), WindowMasks.compute(root).rects)
    }

    @Test
    fun webViewChildrenAreNotWalked() {
        val inner = TextView(context)
        val web = WebView(context).apply { addView(inner, ViewGroup.LayoutParams(100, 50)) }
        val root = column(web to 100)
        layOut(root, 1000, 1000)
        inner.layout(0, 0, 100, 50)
        // The (unlaid-out) WebView yields no rect; a walk would have masked its child.
        assertTrue(WindowMasks.compute(root).rects.isEmpty())
    }

    @Test
    fun hiddenAndSdkOwnedViewsAreSkippedAndBoundsFollowScrollAndClip() {
        val hidden = TextView(context).apply { visibility = View.INVISIBLE }
        val owned = TextView(context).apply { ViewTags.markSdkOwned(this) }
        val shifted = TextView(context).apply { translationX = 900f }
        val root = column(hidden to 100, owned to 100, shifted to 100)
        layOut(root, 1000, 1000)
        // 900 px to the right, clipped at the decor edge: x 0.9, width 0.1.
        val only = WindowMasks.compute(root).rects.single()
        assertEquals(0.9, only.x, 1e-9)
        assertEquals(0.2, only.y, 1e-9)
        assertEquals(0.1, only.width, 1e-9)
        assertEquals(0.1, only.height, 1e-9)
    }

    @Test
    fun anUnreadableWindowFailsClosed() {
        val unlaidOut = FrameLayout(context)
        assertTrue(WindowMasks.compute(unlaidOut).failClosed)
        assertEquals(listOf(MaskRect.FULL_FRAME), WindowMasks.compute(unlaidOut).rects)

        val window = Robolectric.buildActivity(Activity::class.java).get().window
        assertTrue("no decor view yet", WindowMasks.compute(window).failClosed)
    }

    @Test
    fun anActivityWindowIsMaskedInDecorSpace() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        activity.setContentView(FrameLayout(context).apply { addView(TextView(context), FrameLayout.LayoutParams(100, 100)) })
        val decor = activity.window.decorView
        layOut(decor, 1000, 2000)
        val result = WindowMasks.compute(activity.window)
        assertFalse(result.failClosed)
        assertTrue(result.rects.isNotEmpty())
        assertTrue(result.rects.all { it.x in 0.0..1.0 && it.y in 0.0..1.0 && it.width > 0 && it.height > 0 })
    }

    private fun rect(x: Double, y: Double) = MaskRect(x, y, 1.0, 0.1)

    private fun assertRects(expected: List<MaskRect>, actual: List<MaskRect>) {
        assertEquals(actual.toString(), expected.size, actual.size)
        expected.zip(actual).forEach { (e, a) ->
            assertEquals(e.x, a.x, 1e-9)
            assertEquals(e.y, a.y, 1e-9)
            assertEquals(e.width, a.width, 1e-9)
            assertEquals(e.height, a.height, 1e-9)
        }
    }

    private fun column(vararg children: Pair<View, Int>) =
        LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            children.forEach { (view, height) -> addView(view, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, height)) }
        }
}
