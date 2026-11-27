package com.tugboat.android.views.identity

import android.view.View

/**
 * The route a view belongs to (design note 6.1, in priority order):
 *
 * 1. a Jetpack Navigation destination (route, else id entry name): high;
 * 2. the containing fragment's tag: high;
 * 3. the containing fragment's class name: low, because R8 may rename it;
 * 4. the activity's class name: high, because the manifest keeps it.
 *
 * [root] is the view canonical paths start below: the fragment's view, the
 * activity's content view, or the decor view.
 */
internal class RouteKey(val value: String, val confidence: Confidence, val root: View)

/** Resolves the route of any attached view; the navigation module implements it. */
internal fun interface RouteResolver {
    fun routeFor(view: View): RouteKey?

    /**
     * The route of what [decor]'s window shows: by default the route of its
     * `android.R.id.content` view (the decor view when it has none).
     */
    fun visibleRoute(decor: View): RouteKey? = routeFor(decor.findViewById(android.R.id.content) ?: decor)
}
