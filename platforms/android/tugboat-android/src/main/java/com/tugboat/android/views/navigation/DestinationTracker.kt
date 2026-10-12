package com.tugboat.android.views.navigation

import android.app.Activity
import android.content.res.Resources
import java.util.WeakHashMap

/**
 * The current Jetpack Navigation destination per activity: the hook the
 * SDK's optional `Tugboat.trackNavigation(navController)` feeds from
 * `OnDestinationChangedListener`, so this module needs neither the
 * navigation library nor reflection. A destination is the highest-priority
 * route key (design note 6.1): its route pattern, else its id's resource
 * entry name. Main thread only.
 */
internal class DestinationTracker {
    private val current = WeakHashMap<Activity, String>()

    fun onDestinationChanged(activity: Activity, route: String?, destinationId: Int) {
        val key = route?.takeIf { it.isNotEmpty() } ?: entryName(activity.resources, destinationId)
        if (key == null) current.remove(activity) else current[activity] = key
    }

    fun current(activity: Activity): String? = current[activity]

    fun clear(activity: Activity) {
        current.remove(activity)
    }

    private fun entryName(resources: Resources, id: Int): String? =
        try {
            if (id == 0 || id == -1) null else resources.getResourceEntryName(id)
        } catch (_: Resources.NotFoundException) {
            null
        }
}
