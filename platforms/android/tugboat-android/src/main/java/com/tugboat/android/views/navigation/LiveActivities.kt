package com.tugboat.android.views.navigation

import android.app.Activity
import java.lang.ref.WeakReference

/**
 * The activities [NavigationObservation] has seen created (or resumed) and
 * not destroyed, and the one between its resume and pause. Held weakly.
 * Main thread only.
 */
internal class LiveActivities {
    private val activities = ArrayList<WeakReference<Activity>>()
    private var resumed: WeakReference<Activity>? = null

    fun onCreated(activity: Activity) {
        if (activities.none { it.get() === activity }) activities += WeakReference(activity)
    }

    fun onResumed(activity: Activity) {
        onCreated(activity)
        resumed = WeakReference(activity)
    }

    fun onPaused(activity: Activity) {
        if (resumed?.get() === activity) resumed = null
    }

    fun onDestroyed(activity: Activity) {
        activities.removeAll { it.get().let { held -> held == null || held === activity } }
        onPaused(activity)
    }

    fun all(): List<Activity> = activities.mapNotNull { it.get()?.takeUnless(Activity::isDestroyed) }

    fun resumed(): Activity? = resumed?.get()?.takeUnless { it.isFinishing || it.isDestroyed }

    fun clear() {
        activities.clear()
        resumed = null
    }
}
