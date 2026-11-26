package com.tugboat.android.views

import com.tugboat.android.views.scroll.AndroidxScrolling
import com.tugboat.android.views.scroll.NoRecyclerOps
import com.tugboat.android.views.scroll.NoScrollingOps
import com.tugboat.android.views.scroll.RecyclerOps
import com.tugboat.android.views.scroll.RecyclerSupport
import com.tugboat.android.views.scroll.ScrollingOps

/**
 * The optional androidx libraries, decided once per process. The adapter
 * compiles against them (`compileOnly`) but never depends on them: an
 * implementation that names an androidx type is selected only when its
 * library is present (a `Class.forName` probe, no reflection into members),
 * so its class is never loaded in an app without it. `consumer-rules.pro`
 * keeps the probed names when the app's R8 keeps those classes.
 */
internal object OptionalAndroidx {
    val recycler: RecyclerOps =
        if (present("androidx.recyclerview.widget.RecyclerView")) RecyclerSupport else NoRecyclerOps

    val scrolling: ScrollingOps =
        if (present("androidx.core.view.ScrollingView")) AndroidxScrolling else NoScrollingOps

    val fragment: Boolean = present("androidx.fragment.app.FragmentActivity")

    val hasRecyclerView: Boolean
        get() = recycler !== NoRecyclerOps

    private fun present(className: String): Boolean =
        try {
            Class.forName(className, false, OptionalAndroidx::class.java.classLoader)
            true
        } catch (_: Throwable) {
            false
        }
}
