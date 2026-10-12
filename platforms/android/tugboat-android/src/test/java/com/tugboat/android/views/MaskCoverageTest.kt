package com.tugboat.android.views

import android.app.Activity
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.TextView
import androidx.compose.ui.platform.ComposeView
import com.tugboat.android.views.mask.MaskCoverage
import com.tugboat.android.views.mask.MaskMode
import com.tugboat.android.views.mask.MaskReason
import com.tugboat.android.views.mask.WindowMasks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

/** The mask walk's coverage report and structure signature. */
@RunWith(RobolectricTestRunner::class)
class MaskCoverageTest {
    @Test
    fun plainViewsArePrecise() {
        assertEquals(MaskCoverage(MaskMode.Precise), WindowMasks.compute(column(TextView(context))).coverage)
    }

    @Test
    fun opaqueContentIsNotedAndComposeHostsAreWholeHost() {
        val coverage = WindowMasks.compute(column(WebView(context), SurfaceView(context), ComposeView(context))).coverage

        assertEquals(MaskMode.WholeHost, coverage.mode)
        assertEquals(listOf(MaskReason.WebView, MaskReason.SurfaceLayer, MaskReason.ComposeDefault), coverage.reasons)
    }

    @Test
    fun aDetachedWindowIsWholeFrameNoDecor() {
        val window = Robolectric.buildActivity(Activity::class.java).get().window
        assertEquals(MaskCoverage(MaskMode.WholeFrame, listOf(MaskReason.NoDecor)), WindowMasks.compute(window).coverage)
    }

    @Test
    fun theSignatureFollowsStructureAndStateButNotText() {
        val text = TextView(context).apply { text = "one" }
        val box = CheckBox(context)
        val hidden = View(context)
        val root = column(text, box, hidden)
        val before = signature(root)

        text.text = "two"
        assertEquals("text never enters it", before, signature(root))

        box.isChecked = true
        val checked = signature(root)
        assertNotEquals(before, checked)

        box.isChecked = false
        hidden.visibility = View.GONE
        assertNotEquals(before, signature(root))

        hidden.visibility = View.VISIBLE
        text.isSelected = true
        assertNotEquals(before, signature(root))

        text.isSelected = false
        assertEquals("back to the same structure", before, signature(root))
    }

    @Test
    fun aMovedMaskChangesTheSignature() {
        val text = TextView(context)
        val root = column(text)
        val before = signature(root)

        text.translationY = 300f

        assertNotEquals(before, signature(root))
    }

    private fun signature(root: View) = WindowMasks.compute(root).structureSignature

    private fun column(vararg children: View): ViewGroup =
        LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            children.forEach { addView(it, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 100)) }
            layOut(this, 1000, 1000)
        }
}
