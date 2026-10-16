package com.tugboat.android.views

import android.view.ViewGroup
import android.view.animation.AlphaAnimation
import android.view.animation.Transformation
import android.widget.LinearLayout
import android.widget.TextView
import com.tugboat.android.toolkit.MaskCoverageReason
import com.tugboat.android.views.mask.MaskCoverage
import com.tugboat.android.views.mask.MaskRect
import com.tugboat.android.views.mask.WindowMasks
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The motion check runs before the region mask walk: a frame in motion is
 * masked whole as `animating` without asking any toolkit region for masks.
 */
@RunWith(RobolectricTestRunner::class)
class MaskOrderTest {
    @get:Rule
    val regionRule = FakeRegionRule()

    private val text = TextView(context)
    private val root = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        addView(text, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 200))
        addView(FakeHostView(context), LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 600))
        layOut(this, 1000, 1000)
    }

    @Test
    fun anAnimatingFrameIsWholeFrameAnimatingAndNoRegionIsAsked() {
        // A region that is asked fails the walk (walkExhausted): it must not be asked.
        regionRule.region.throwing = true
        text.animation = AlphaAnimation(0f, 1f).apply {
            duration = 10_000
            initialize(100, 100, 100, 100)
            getTransformation(0, Transformation())
        }

        val result = WindowMasks.compute(root)

        assertEquals(MaskCoverage.wholeFrame(MaskCoverageReason.Animating), result.coverage)
        assertEquals("""{"mode":"wholeFrame","reasons":["animating"]}""", result.coverage.toJson().toString())
        assertEquals(listOf(MaskRect.FULL_FRAME), result.rects)
    }

    @Test
    fun withoutMotionTheRegionIsAsked() {
        regionRule.region.throwing = true

        assertEquals(MaskCoverage.wholeFrame(MaskCoverageReason.WalkExhausted), WindowMasks.compute(root).coverage)
    }
}
