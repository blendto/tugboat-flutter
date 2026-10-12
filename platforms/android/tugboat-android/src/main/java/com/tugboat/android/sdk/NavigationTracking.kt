package com.tugboat.android.sdk

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.os.Bundle
import android.util.Log
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavController
import androidx.navigation.NavDestination
import com.tugboat.android.views.AdapterGuard
import com.tugboat.android.views.navigation.NavEntry
import java.lang.ref.WeakReference

/**
 * `Tugboat.trackNavigation(navController)`: feeds Jetpack Navigation
 * destinations to the Views adapter, both as route keys (design note 6.1:
 * the destination route pattern without arguments, else its id's resource
 * entry name) and as `navigation` facts on the controller's own navigator.
 * Each change carries the new current back-stack entry and the one below it
 * (public `currentBackStackEntry` / `previousBackStackEntry`). The
 * navigation library is `compileOnly`; only apps that have it can call this.
 */
internal object NavigationTracking {
    private const val TAG = "Tugboat"

    /** [onChange] receives the hosting activity, the current entry, and the one below it. */
    fun track(navController: NavController, onChange: (Activity, NavEntry, NavEntry?) -> Unit) {
        val activity = navController.context.findActivity()
        if (activity == null) {
            Log.w(TAG, "trackNavigation: the NavController has no activity context; ignored")
            return
        }
        navController.addOnDestinationChangedListener(DestinationForwarder(activity, onChange))
    }

    private tailrec fun Context.findActivity(): Activity? =
        when (this) {
            is Activity -> this
            is ContextWrapper -> baseContext?.findActivity()
            else -> null
        }
}

/** Holds the activity weakly: the NavController may outlive it. */
internal class DestinationForwarder(
    activity: Activity,
    private val onChange: (Activity, NavEntry, NavEntry?) -> Unit,
) : NavController.OnDestinationChangedListener {
    private val activity = WeakReference(activity)

    override fun onDestinationChanged(controller: NavController, destination: NavDestination, arguments: Bundle?) =
        AdapterGuard.run("navigation destination") {
            val host = activity.get() ?: return@run
            val current = controller.currentBackStackEntry?.toNavEntry() ?: return@run
            onChange(host, current, controller.previousBackStackEntry?.toNavEntry())
        }

    private fun NavBackStackEntry.toNavEntry() = NavEntry(id, destination.route, destination.id)
}
