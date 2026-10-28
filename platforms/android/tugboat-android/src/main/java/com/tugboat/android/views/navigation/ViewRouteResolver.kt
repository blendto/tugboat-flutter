package com.tugboat.android.views.navigation

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.view.View
import com.tugboat.android.views.identity.Confidence
import com.tugboat.android.views.identity.RouteKey
import com.tugboat.android.views.identity.RouteResolver

/**
 * Route keys for views (design note 6.1). A view inside a shown fragment's
 * view takes that fragment's route key (destination, else tag, else class),
 * fixed when the fragment was shown, and paths start below the fragment's
 * view. Any other view takes its activity's current navigation destination,
 * else the activity class name, and paths start below `android.R.id.content`
 * (or the decor view for views outside it, such as a window-level toolbar).
 * A window's visible route ([visibleRoute], the scene inventory's) walks
 * down instead, to the topmost shown fragment.
 */
internal class ViewRouteResolver(
    private val destinations: DestinationTracker,
    /** The shown fragment route rooted at a view ([FragmentNavigation.routeRootedAt]); none without androidx.fragment. */
    private val fragmentRoute: (View) -> RouteEntry? = { null },
    /** The topmost shown fragment root of an activity ([FragmentNavigation.visibleRouteRoot]); none without androidx.fragment. */
    private val visibleFragmentRoot: (Activity) -> View? = { null },
) : RouteResolver {
    /**
     * The route of the visible content: the topmost shown fragment's below
     * `android.R.id.content`, else the activity's (its destination, else its
     * class), rooted at the content view.
     */
    override fun visibleRoute(decor: View): RouteKey? {
        val content = decor.findViewById<View>(android.R.id.content) ?: return routeFor(decor)
        val root = activityOf(content.context)?.let(visibleFragmentRoot) ?: content
        return routeFor(root)
    }

    override fun routeFor(view: View): RouteKey? {
        var current: View? = view
        while (current != null) {
            fragmentRoute(current)?.let { return RouteKey(it.routeKey, it.confidence, current) }
            current = current.parent as? View
        }
        val activity = activityOf(view.context) ?: return null
        val root = contentRoot(view)
        val destination = destinations.current(activity)
        return RouteKey(destination ?: activity.javaClass.name, Confidence.High, root)
    }

    private fun contentRoot(view: View): View {
        val window = view.rootView
        val content = window.findViewById<View>(android.R.id.content) ?: return window
        var current: View? = view
        while (current != null) {
            if (current === content) return content
            current = current.parent as? View
        }
        return window
    }

    companion object {
        fun activityOf(context: Context?): Activity? {
            var current = context
            while (current is ContextWrapper) {
                if (current is Activity) return current
                current = current.baseContext
            }
            return null
        }
    }
}
