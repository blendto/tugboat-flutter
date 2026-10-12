package com.tugboat.android.views.identity

import android.view.View
import androidx.core.view.ScrollingView
import com.tugboat.android.views.OptionalAndroidx

/**
 * `androidx.core` `ScrollingView` metrics. Only called when
 * [OptionalAndroidx.scrollingView] is true, so this class (and the androidx
 * types it names) is never loaded in an app without androidx.core.
 */
internal object AndroidxScrolling {
    fun isScrollingView(view: View): Boolean = view is ScrollingView

    fun metrics(view: View): ScrollMetrics? {
        if (view !is ScrollingView) return null
        val axis = axis(view)
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

    private fun axis(view: ScrollingView): ScrollAxis {
        if (OptionalAndroidx.recyclerView) RecyclerSupport.axis(view as View)?.let { return it }
        val horizontalOnly = view.computeHorizontalScrollRange() > view.computeHorizontalScrollExtent() &&
            view.computeVerticalScrollRange() <= view.computeVerticalScrollExtent()
        return if (horizontalOnly) ScrollAxis.Horizontal else ScrollAxis.Vertical
    }
}
