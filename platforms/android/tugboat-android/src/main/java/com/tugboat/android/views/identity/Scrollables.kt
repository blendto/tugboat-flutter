package com.tugboat.android.views.identity

import android.view.View
import android.widget.AbsListView
import android.widget.HorizontalScrollView
import android.widget.ScrollView
import com.tugboat.android.views.OptionalAndroidx

/** Engine `scroll.axis` values (Dart `Axis.name`). */
internal enum class ScrollAxis(val wire: String) {
    Vertical("vertical"),
    Horizontal("horizontal"),
}

/** One scrollable's position in physical pixels; [maxExtentPx] null when unknown. */
internal data class ScrollMetrics(val axis: ScrollAxis, val offsetPx: Float, val maxExtentPx: Float?)

/**
 * The scrollables the adapter knows: `ScrollView`, `HorizontalScrollView`,
 * `AbsListView` (`ListView`, `GridView`), and, when androidx is present,
 * every `ScrollingView` (`NestedScrollView`, `RecyclerView`).
 *
 * `AbsListView` exposes no public pixel offset, so its offset is estimated
 * from the first visible row (first position x row height - row top), and
 * its extent is unknown.
 */
internal object Scrollables {
    fun isScrollable(view: View): Boolean =
        view is ScrollView || view is HorizontalScrollView || view is AbsListView ||
            (OptionalAndroidx.scrollingView && AndroidxScrolling.isScrollingView(view))

    fun metrics(view: View): ScrollMetrics? =
        when {
            view is ScrollView -> ScrollMetrics(ScrollAxis.Vertical, view.scrollY.toFloat(), verticalExtent(view))
            view is HorizontalScrollView ->
                ScrollMetrics(ScrollAxis.Horizontal, view.scrollX.toFloat(), horizontalExtent(view))
            view is AbsListView -> ScrollMetrics(ScrollAxis.Vertical, listOffset(view), null)
            OptionalAndroidx.scrollingView -> AndroidxScrolling.metrics(view)
            else -> null
        }

    private fun verticalExtent(view: ScrollView): Float {
        val child = view.getChildAt(0) ?: return 0f
        val viewport = view.height - view.paddingTop - view.paddingBottom
        return (child.height - viewport).coerceAtLeast(0).toFloat()
    }

    private fun horizontalExtent(view: HorizontalScrollView): Float {
        val child = view.getChildAt(0) ?: return 0f
        val viewport = view.width - view.paddingLeft - view.paddingRight
        return (child.width - viewport).coerceAtLeast(0).toFloat()
    }

    private fun listOffset(view: AbsListView): Float {
        val first = view.getChildAt(0) ?: return 0f
        return (view.firstVisiblePosition * first.height - first.top).toFloat()
    }
}
