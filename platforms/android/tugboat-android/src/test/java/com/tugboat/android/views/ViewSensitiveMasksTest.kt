package com.tugboat.android.views

import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import com.tugboat.android.tugboatSensitive
import com.tugboat.android.views.compose.covered
import com.tugboat.android.views.mask.WindowMasks
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** `View.tugboatSensitive()` masks under `allTextAndMedia` (the only native level). */
@RunWith(RobolectricTestRunner::class)
class ViewSensitiveMasksTest {
    @Test
    fun sensitivePlainViewIsMaskedAndSiblingIsNot() {
        val sensitive = View(context).tugboatSensitive()
        val plain = View(context)
        val root = column(sensitive to 100, plain to 100)
        layOut(root, 1000, 1000)
        val result = WindowMasks.compute(root)
        val decor = root
        assertTrue(covered(result.rects, viewBounds(sensitive, decor), decor))
        assertFalse(covered(result.rects, viewBounds(plain, decor), decor))
    }

    @Test
    fun sensitiveParentMasksItsSubtree() {
        val parent = FrameLayout(context).apply { tugboatSensitive() }
        val child = View(context)
        parent.addView(child, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 100))
        val root = column(parent to 100)
        layOut(root, 1000, 1000)
        val result = WindowMasks.compute(root)
        assertTrue(covered(result.rects, viewBounds(child, root), root))
    }

    @Test
    fun sensitiveInsideAlreadyMaskedRegionDoesNotRemoveCoverage() {
        val text = TextView(context)
        val root = column(text to 100)
        layOut(root, 1000, 1000)
        val bounds = viewBounds(text, root)
        val before = WindowMasks.compute(root)
        assertTrue(covered(before.rects, bounds, root))
        text.tugboatSensitive()
        val after = WindowMasks.compute(root)
        assertTrue(covered(after.rects, bounds, root))
    }

    private fun viewBounds(view: View, decor: View): androidx.compose.ui.geometry.Rect {
        var left = 0f
        var top = 0f
        var current: View? = view
        while (current != null && current !== decor) {
            left += current.left
            top += current.top
            current = current.parent as? View
        }
        return androidx.compose.ui.geometry.Rect(left, top, left + view.width, top + view.height)
    }

    private fun column(vararg children: Pair<View, Int>) =
        LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            children.forEach { (view, height) -> addView(view, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, height)) }
        }
}
