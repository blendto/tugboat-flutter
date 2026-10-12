package com.tugboat.android.views

import android.animation.LayoutTransition
import android.view.View
import android.view.ViewGroup
import android.view.animation.AlphaAnimation
import android.view.animation.Animation
import android.view.animation.Transformation
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import com.tugboat.android.views.identity.ViewTags
import com.tugboat.android.views.mask.FailClosedReason
import com.tugboat.android.views.mask.MaskRect
import com.tugboat.android.views.mask.WindowMasks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Motion the layout bounds do not describe masks the whole frame: a frame
 * copied mid-animation can show text outside its mask.
 */
@RunWith(RobolectricTestRunner::class)
class MaskAnimationTest {
    @Test
    fun aRunningLegacyAnimationOnAVisibleViewMasksTheWholeFrame() {
        val text = TextView(context)
        val root = column(text)
        text.animation = started(AlphaAnimation(0f, 1f).apply { duration = 10_000 })

        val result = WindowMasks.compute(root)

        assertTrue(result.failClosed)
        assertEquals(FailClosedReason.Animating, result.reason)
        assertEquals(listOf(MaskRect.FULL_FRAME), result.rects)
    }

    @Test
    fun anAnimationOnTheContainerAlsoCounts() {
        val root = column(TextView(context))
        root.animation = started(AlphaAnimation(0f, 1f).apply { duration = 10_000 })

        assertEquals(FailClosedReason.Animating, WindowMasks.compute(root).reason)
    }

    @Test
    fun notStartedAndEndedAnimationsDoNot() {
        val pending = TextView(context).apply { animation = AlphaAnimation(0f, 1f) }
        val ended = TextView(context).apply {
            animation = AlphaAnimation(0f, 1f).apply {
                duration = 1
                val out = Transformation()
                getTransformation(0, out)
                getTransformation(10, out)
            }
        }
        val root = column(pending, ended)
        assertTrue("precondition: ended", ended.animation.hasEnded())

        val result = WindowMasks.compute(root)

        assertFalse(result.failClosed)
        assertNull(result.reason)
        assertEquals(2, result.rects.size)
    }

    @Test
    fun aRunningLayoutTransitionMasksTheWholeFrame() {
        val inner = FrameLayout(context).apply {
            layoutTransition = RunningTransition()
            addView(TextView(context), FrameLayout.LayoutParams(100, 50))
        }
        val root = column(inner)

        assertEquals(FailClosedReason.Animating, WindowMasks.compute(root).reason)
    }

    @Test
    fun hiddenAndSdkOwnedSubtreesAreIgnored() {
        val hidden = TextView(context).apply { visibility = View.GONE }
        val owned = FrameLayout(context).apply { ViewTags.markSdkOwned(this) }
        val ownedChild = TextView(context)
        owned.addView(ownedChild)
        val root = column(hidden, owned)
        hidden.animation = started(AlphaAnimation(0f, 1f).apply { duration = 10_000 })
        ownedChild.animation = started(AlphaAnimation(0f, 1f).apply { duration = 10_000 })

        assertFalse(WindowMasks.compute(root).failClosed)
    }

    @Test
    fun anUnreadableTreeReportsItsReason() {
        assertEquals(FailClosedReason.TreeUnreadable, WindowMasks.compute(FrameLayout(context)).reason)
    }

    private fun started(animation: Animation): Animation = animation.apply {
        initialize(100, 100, 100, 100)
        getTransformation(0, Transformation())
    }

    private fun column(vararg children: View): ViewGroup =
        LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            children.forEach { addView(it, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 100)) }
            layOut(this, 1000, 1000)
        }

    private class RunningTransition : LayoutTransition() {
        override fun isRunning(): Boolean = true
    }
}
