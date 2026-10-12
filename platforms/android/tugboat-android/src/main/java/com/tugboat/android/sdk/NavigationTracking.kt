package com.tugboat.android.sdk

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.os.Bundle
import android.util.Log
import androidx.navigation.NavController
import androidx.navigation.NavDestination
import com.tugboat.android.views.AdapterGuard
import java.lang.ref.WeakReference

/**
 * `Tugboat.trackNavigation(navController)`: feeds Jetpack Navigation
 * destinations to the Views adapter's route keys (design note 6.1: the
 * destination route pattern, else its id's resource entry name). The
 * navigation library is `compileOnly`; only apps that have it can call this.
 */
internal object NavigationTracking {
    private const val TAG = "Tugboat"

    /** [onChange] receives the hosting activity, the route pattern, and the destination id. */
    fun track(navController: NavController, onChange: (Activity, String?, Int) -> Unit) {
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
    private val onChange: (Activity, String?, Int) -> Unit,
) : NavController.OnDestinationChangedListener {
    private val activity = WeakReference(activity)

    override fun onDestinationChanged(controller: NavController, destination: NavDestination, arguments: Bundle?) =
        AdapterGuard.run("navigation destination") {
            activity.get()?.let { onChange(it, destination.route, destination.id) }
        }
}
