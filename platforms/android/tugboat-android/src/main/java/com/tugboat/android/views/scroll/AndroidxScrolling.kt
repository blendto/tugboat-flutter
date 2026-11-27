package com.tugboat.android.views.scroll

import android.view.View
import androidx.core.view.ScrollingView
import com.tugboat.android.views.OptionalAndroidx

/** `androidx.core` `ScrollingView` support; [OptionalAndroidx.scrolling] picks the implementation once. */
internal interface ScrollingOps {
    fun isScrollingView(view: View): Boolean

    fun metrics(view: View): ScrollMetrics?
}

/** The app has no androidx.core. */
internal object NoScrollingOps : ScrollingOps {
    override fun isScrollingView(view: View) = false

    override fun metrics(view: View): ScrollMetrics? = null
}

/**
 * `ScrollingView` (`NestedScrollView`, `RecyclerView`) metrics. Referenced
 * only from [OptionalAndroidx] when androidx.core is present, so the class
 * (and the androidx types it names) is never loaded in an app without it.
 */
internal object AndroidxScrolling : ScrollingOps {
    override fun isScrollingView(view: View): Boolean = view is ScrollingView

    override fun metrics(view: View): ScrollMetrics? {
        if (view !is ScrollingView) return null
        val axis = OptionalAndroidx.recycler.axis(view as View) ?: rangeAxis(view)
        return if (axis == ScrollAxis.Vertical) {
            ScrollMetrics(
                axis,
                view.computeVerticalScrollOffset().toFloat(),
                (view.computeVerticalScrollRange() - view.computeVerticalScrollExtent()).coerceAtLeast(0).toFloat(),
            )
        } else {
            ScrollMetrics(
                axis,
                view.computeHorizontalScrollOffset().toFloat(),
                (view.computeHorizontalScrollRange() - view.computeHorizontalScrollExtent()).coerceAtLeast(0).toFloat(),
            )
        }
    }

    private fun rangeAxis(view: ScrollingView): ScrollAxis {
        val horizontalOnly = view.computeHorizontalScrollRange() > view.computeHorizontalScrollExtent() &&
            view.computeVerticalScrollRange() <= view.computeVerticalScrollExtent()
        return if (horizontalOnly) ScrollAxis.Horizontal else ScrollAxis.Vertical
    }
}
