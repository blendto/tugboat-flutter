package com.tugboat.android.views

import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.compose.ui.geometry.Rect
import com.tugboat.android.tugboatSensitive
import com.tugboat.android.views.compose.covered
import com.tugboat.android.views.identity.AndroidResourceNames
import com.tugboat.android.views.identity.ViewRules
import com.tugboat.android.views.mask.MaskRect
import com.tugboat.android.views.mask.WindowMasks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * `View.tugboatSensitive()` under `allTextAndMedia` (the only native level):
 * masks only add coverage, one rect per view, and identity is untouched.
 * Every root is 1000 x 1000 px.
 */
@RunWith(RobolectricTestRunner::class)
class ViewSensitiveMasksTest {
    @Test
    fun sensitivePlainViewIsMaskedAndSiblingIsNot() {
        val sensitive = View(context).tugboatSensitive()
        val plain = View(context)
        val root = column(sensitive to 100, plain to 100)
        layOut(root, 1000, 1000)
        val result = WindowMasks.compute(root)
        assertEquals(listOf(MaskRect(0.0, 0.0, 1.0, 0.1)), result.rects)
        assertFalse(covered(result.rects, Rect(0f, 100f, 1000f, 200f), root))
    }

    @Test
    fun sensitiveParentMasksADeepChildDrawnOutsideIt() {
        // parent (y 0-100) > middle (inside it) > deep, translated to y 150-250.
        val deep = View(context).apply { translationY = 150f }
        val middle = FrameLayout(context).apply {
            clipChildren = false
            addView(deep, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 100))
        }
        val parent = FrameLayout(context).tugboatSensitive().apply {
            clipChildren = false
            addView(middle, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 100))
        }
        val root = column(parent to 100).apply { clipChildren = false }
        layOut(root, 1000, 1000)
        val result = WindowMasks.compute(root)
        assertTrue(covered(result.rects, Rect(0f, 0f, 1000f, 100f), root))
        assertTrue("the deep child outside its sensitive parent: ${result.rects}", covered(result.rects, Rect(0f, 150f, 1000f, 250f), root))
        assertEquals("the middle view, inside the parent's rect, adds none: ${result.rects}", 2, result.rects.size)
    }

    @Test
    fun aSensitiveViewTheWalkAlreadyMasksYieldsOneRect() {
        val text = TextView(context).tugboatSensitive()
        val root = column(text to 100)
        layOut(root, 1000, 1000)
        assertEquals(listOf(MaskRect(0.0, 0.0, 1.0, 0.1)), WindowMasks.compute(root).rects)
    }

    @Test
    fun aChildFillingItsSensitiveParentAddsNoSecondRect() {
        val parent = FrameLayout(context).tugboatSensitive().apply {
            addView(View(context), ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        }
        val root = column(parent to 100)
        layOut(root, 1000, 1000)
        assertEquals(listOf(MaskRect(0.0, 0.0, 1.0, 0.1)), WindowMasks.compute(root).rects)
    }

    @Test
    fun sensitiveInsideAlreadyMaskedRegionDoesNotRemoveCoverage() {
        val text = TextView(context)
        val root = column(text to 100)
        layOut(root, 1000, 1000)
        val before = WindowMasks.compute(root)
        text.tugboatSensitive()
        assertEquals(before.rects, WindowMasks.compute(root).rects)
    }

    @Test
    fun sensitiveChangesNoTapTargetPathOrFingerprint() {
        val plain = Screen(sensitive = false)
        val marked = Screen(sensitive = true)
        for ((tap, y) in Screen.taps) {
            val expected = plain.evidence(y)
            if (tap != "box padding") assertNotNull("$tap resolves", expected.anchor)
            assertEquals(tap, expected.toJson().toString(), marked.evidence(y).toJson().toString())
        }
        val names = AndroidResourceNames(context.resources)
        assertEquals(ViewRules.isKept(plain.box, names), ViewRules.isKept(marked.box, names))
        assertEquals(ViewRules.isKept(plain.b, names), ViewRules.isKept(marked.b, names))
    }

    /** `A; box(padding 50) { B }; C`, with the box and B marked sensitive or not. */
    private class Screen(sensitive: Boolean) {
        val b = Button(context)
        val box = FrameLayout(context).apply {
            setPadding(50, 50, 50, 50)
            addView(b, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 100))
        }
        val root = column(Button(context) to 100, box to 200, Button(context) to 100)
        private val anchors = anchorResolver(root, routeKey = "com.example.FormActivity")

        init {
            if (sensitive) {
                box.tugboatSensitive()
                b.tugboatSensitive()
            }
            layOut(root, 1000, 1000)
        }

        fun evidence(y: Float) = anchors.tapEvidence(root, 500f, y)

        companion object {
            /** Tap heights: A, B, the box's blank padding, and C. */
            val taps = mapOf("A" to 50f, "B" to 200f, "box padding" to 125f, "C" to 350f)
        }
    }

    private companion object {
        fun column(vararg children: Pair<View, Int>) =
            LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                children.forEach { (view, height) -> addView(view, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, height)) }
            }
    }
}
