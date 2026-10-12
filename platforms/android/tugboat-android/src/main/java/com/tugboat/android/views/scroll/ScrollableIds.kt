package com.tugboat.android.views.scroll

import android.view.View
import java.util.WeakHashMap

/** Stable opaque `scrollableId`s: one per scrollable instance, for its lifetime. */
internal object ScrollableIds {
    private val ids = WeakHashMap<View, String>()
    private var next = 1L

    fun of(view: View): String = synchronized(ids) { ids.getOrPut(view) { "view-scroll-${next++}" } }
}
