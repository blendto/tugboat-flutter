package com.tugboat.android.views.identity

import android.view.View

/** Fingerprint confidence tiers, lowest first; [floor] takes the weakest. */
internal enum class Confidence(val wire: String) {
    Low("low"),
    Medium("medium"),
    High("high"),
    ;

    companion object {
        fun floor(vararg tiers: Confidence): Confidence = tiers.minByOrNull { it.ordinal } ?: High
    }
}

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
}
