package com.tugboat.android.views.scroll

import android.view.View
import androidx.recyclerview.widget.RecyclerView
import com.tugboat.android.views.OptionalAndroidx

/** What the adapter needs from `RecyclerView`; [OptionalAndroidx.recycler] picks the implementation once. */
internal interface RecyclerOps {
    fun isRecyclerView(view: View): Boolean

    /** The layout manager's axis, or null when [view] has no layout manager. */
    fun axis(view: View): ScrollAxis?

    /** [child]'s adapter position in [list], then its layout position, or null. */
    fun itemIndex(list: View, child: View): Int?
}

/** The app has no androidx.recyclerview. */
internal object NoRecyclerOps : RecyclerOps {
    override fun isRecyclerView(view: View) = false

    override fun axis(view: View): ScrollAxis? = null

    override fun itemIndex(list: View, child: View): Int? = null
}

/**
 * Everything that touches `RecyclerView`. Referenced only from
 * [OptionalAndroidx] when androidx.recyclerview is present, so the class is
 * never loaded in an app without it.
 */
internal object RecyclerSupport : RecyclerOps {
    override fun isRecyclerView(view: View): Boolean = view is RecyclerView

    override fun axis(view: View): ScrollAxis? {
        val manager = (view as? RecyclerView)?.layoutManager ?: return null
        val horizontal = !manager.canScrollVertically() && manager.canScrollHorizontally()
        return if (horizontal) ScrollAxis.Horizontal else ScrollAxis.Vertical
    }

    override fun itemIndex(list: View, child: View): Int? {
        val recycler = list as? RecyclerView ?: return null
        val adapter = recycler.getChildAdapterPosition(child)
        if (adapter != RecyclerView.NO_POSITION) return adapter
        return recycler.getChildLayoutPosition(child).takeIf { it != RecyclerView.NO_POSITION }
    }
}
