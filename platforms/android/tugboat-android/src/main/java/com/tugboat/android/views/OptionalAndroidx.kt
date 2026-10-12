package com.tugboat.android.views

/**
 * Which optional androidx libraries the app ships. The adapter compiles
 * against them (`compileOnly`) but never depends on them: code that touches
 * an androidx type runs only behind its flag, so the class is never loaded
 * in an app without it. Plain `Class.forName` presence checks, no reflection
 * into members.
 */
internal object OptionalAndroidx {
    val recyclerView: Boolean = present("androidx.recyclerview.widget.RecyclerView")
    val fragment: Boolean = present("androidx.fragment.app.FragmentActivity")

    /** `androidx.core`'s `ScrollingView` (NestedScrollView, RecyclerView). */
    val scrollingView: Boolean = present("androidx.core.view.ScrollingView")

    private fun present(className: String): Boolean =
        try {
            Class.forName(className, false, OptionalAndroidx::class.java.classLoader)
            true
        } catch (_: Throwable) {
            false
        }
}
