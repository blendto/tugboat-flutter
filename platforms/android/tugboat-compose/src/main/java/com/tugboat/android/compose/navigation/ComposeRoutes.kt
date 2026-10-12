package com.tugboat.android.compose.navigation

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.view.View
import java.util.WeakHashMap

/**
 * Compose route keys (native SDK note 6.2): the `trackNavigation` route
 * pattern of the host's activity with its arguments stripped
 * ([RoutePattern.strip]); null leaves the host's Views route (the hosting
 * activity, or the fragment around a `ComposeView`).
 *
 * The plain-string hook needs no Navigation Compose dependency: the SDK
 * facade registers `navController.addOnDestinationChangedListener` and
 * passes `destination.route` to the Views adapter's `onDestinationChanged`,
 * which forwards it here. Main thread only.
 */
internal class ComposeRoutes {
    private val routes = WeakHashMap<Activity, String>()

    fun onDestinationChanged(activity: Activity, route: String?) {
        val key = RoutePattern.strip(route)
        if (key == null) routes.remove(activity) else routes[activity] = key
    }

    fun routeFor(host: View): String? = activityOf(host.context)?.let(routes::get)

    private fun activityOf(context: Context?): Activity? {
        var current = context
        while (current is ContextWrapper) {
            if (current is Activity) return current
            current = current.baseContext
        }
        return null
    }
}

/** Navigation route patterns without their arguments. */
internal object RoutePattern {
    /**
     * `profile/{userId}?tab={tab}` becomes `profile`; a type-safe route
     * `com.example.Profile/{id}` becomes `com.example.Profile`. Null when
     * nothing is left.
     */
    fun strip(route: String?): String? {
        val path = route?.substringBefore('?') ?: return null
        return path.split('/')
            .filter { it.isNotEmpty() && !it.contains('{') }
            .joinToString(separator = "/")
            .takeIf { it.isNotEmpty() }
    }
}
