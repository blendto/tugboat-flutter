package com.tugboat.android.views.navigation

import android.app.Activity
import android.app.Application
import android.os.Bundle
import com.tugboat.android.views.AdapterGuard
import com.tugboat.android.views.OptionalAndroidx

/**
 * Process-scoped navigation observation (activity, fragment, and NavController
 * stacks). Registered on the first adapter [start] and left registered after
 * [com.tugboat.android.views.ViewsAdapter.stop]; stacks keep updating while
 * stopped but nothing is emitted until a recording adapter is attached.
 *
 * Main thread only.
 */
internal object NavigationObservation : Application.ActivityLifecycleCallbacks {
    private var application: Application? = null
    private var installed = false
    // Held strongly while an adapter records; [setRecording] (null) in
    // `ViewsAdapter.stop` releases it. A weak reference would lose the
    // adapter's bound `::reportNavigation` at the next GC.
    private var recording: ((NavigationChange) -> Unit)? = null
    var requestFrame: () -> Unit = {}

    private val destinations = DestinationTracker()
    lateinit var routes: ViewRouteResolver
        private set
    private lateinit var activities: ActivityNavigation
    private var fragments: FragmentNavigation? = null
    private lateinit var controllers: ControllerNavigation

    fun resetForTests() {
        if (installed) {
            application?.unregisterActivityLifecycleCallbacks(this)
            installed = false
            application = null
        }
        recording = null
        requestFrame = {}
        NavigationProcessState.resetForTests()
    }

    fun ensureInstalled(app: Application) {
        if (installed) return
        application = app
        routes = ViewRouteResolver(destinations) { view -> fragments?.routeRootedAt(view) }
        activities = ActivityNavigation(::report)
        controllers = ControllerNavigation(::report)
        fragments =
            if (OptionalAndroidx.fragment) {
                FragmentNavigation(activities, destinations, ::report, requestFrame = { requestFrame() })
            } else {
                null
            }
        app.registerActivityLifecycleCallbacks(this)
        installed = true
    }

    fun setRecording(report: ((NavigationChange) -> Unit)?) {
        recording = report
    }

    fun flushFragments() {
        fragments?.flush()
    }

    val fragmentNavigatorIds: Set<String>
        get() = fragments?.navigatorIds.orEmpty()

    fun ensureEntry(activity: Activity): RouteEntry = activities.ensureEntry(activity)

    fun navigatorIdOf(activity: Activity): String = activities.navigatorIdOf(activity)

    fun onDestinationChanged(activity: Activity, route: String?, destinationId: Int) =
        AdapterGuard.run("destination changed") { destinations.onDestinationChanged(activity, route, destinationId) }

    fun onNavDestination(activity: Activity, current: NavEntry, previous: NavEntry?) =
        AdapterGuard.run("nav destination") {
            destinations.onDestinationChanged(activity, current.route, current.destinationId)
            val navigatorId = ControllerNavigation.navigatorIdFor(ensureEntry(activity).instanceId)
            val routeKey =
                destinations.routeKey(activity, current.route, current.destinationId)
                    ?: ControllerNavigation.TYPE
            onNavDestination(
                activity,
                navigatorId,
                navigatorIdOf(activity),
                current,
                routeKey,
                previous,
            )
        }

    fun onNavDestination(
        activity: Activity,
        navigatorId: String,
        parentNavigatorId: String,
        current: NavEntry,
        routeKey: String,
        previous: NavEntry?,
    ) = AdapterGuard.run("nav destination") {
        destinations.onDestinationChanged(activity, current.route, current.destinationId)
        controllers.onDestinationChanged(navigatorId, parentNavigatorId, current, routeKey, previous)
    }

    private fun report(change: NavigationChange) {
        recording?.invoke(change)
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) =
        AdapterGuard.run("activity created") {
            activities.onCreated(activity)
            fragments?.register(activity)
        }

    override fun onActivityResumed(activity: Activity) =
        AdapterGuard.run("activity resumed") { activities.onResumed(activity) }

    override fun onActivityDestroyed(activity: Activity) =
        AdapterGuard.run("activity destroyed") {
            fragments?.unregister(activity)
            if (activity.isFinishing) {
                fragments?.forget(activity)
                destinations.clear(activity)
                activities.entryOf(activity)?.let {
                    controllers.forget(ControllerNavigation.navigatorIdFor(it.instanceId))
                }
            }
            activities.onDestroyed(activity)
        }

    override fun onActivityStarted(activity: Activity) = Unit

    override fun onActivityPaused(activity: Activity) = Unit

    override fun onActivityStopped(activity: Activity) = Unit

    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
}
