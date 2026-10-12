package com.tugboat.android.views.identity

import android.view.View
import androidx.recyclerview.widget.RecyclerView
import com.tugboat.android.views.OptionalAndroidx

/**
 * Everything that touches `RecyclerView`. Only called when
 * [OptionalAndroidx.recyclerView] is true, so the class is never loaded in
 * an app without androidx.recyclerview.
 */
internal object RecyclerSupport {
    fun isRecyclerView(view: View): Boolean = view is RecyclerView

    /** The layout manager's axis, or null when [view] has no layout manager. */
    fun axis(view: View): ScrollAxis? {
        val manager = (view as? RecyclerView)?.layoutManager ?: return null
        val horizontal = !manager.canScrollVertically() && manager.canScrollHorizontally()
        return if (horizontal) ScrollAxis.Horizontal else ScrollAxis.Vertical
    }

    /**
     * [child]'s adapter position in [list], then its layout position, or null
     * when it has neither (a child being removed).
     */
    fun itemIndex(list: View, child: View): Int? {
        val recycler = list as? RecyclerView ?: return null
        val adapter = recycler.getChildAdapterPosition(child)
        if (adapter != RecyclerView.NO_POSITION) return adapter
        return recycler.getChildLayoutPosition(child).takeIf { it != RecyclerView.NO_POSITION }
    }
}
