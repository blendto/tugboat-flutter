package com.tugboat.android.views.navigation

import android.view.View
import java.util.WeakHashMap

/** Root views of fragment routes, registered while their fragment is shown. Main thread only. */
internal class RouteRoots {
    private val roots = WeakHashMap<View, RouteEntry>()

    operator fun get(view: View): RouteEntry? = roots[view]

    operator fun set(view: View, entry: RouteEntry) {
        roots[view] = entry
    }

    fun remove(view: View) {
        roots.remove(view)
    }
}
