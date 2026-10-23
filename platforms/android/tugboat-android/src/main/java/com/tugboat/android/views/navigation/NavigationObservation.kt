package com.tugboat.android.views.navigation

import android.app.Activity
import android.app.Application
import android.os.Bundle
import com.tugboat.android.views.AdapterGuard
import com.tugboat.android.views.OptionalAndroidx
import com.tugboat.android.views.facts.ChoreographerFrames
import com.tugboat.android.views.facts.FrameScheduler

/**
 * Process-scoped navigation observation (activity, fragment, and NavController
 * stacks). Installed from the first [com.tugboat.android.views.ViewsAdapter]
 * construction and left registered after [stop]; stacks keep updating while
 * stopped but nothing is emitted until a recording adapter is attached.
 * NavController stacks reported before installation are discarded when it
 * installs ([ensureInstalled]).
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

    private var frameScheduler: FrameScheduler = ChoreographerFrames()
    private var frameScheduled = false

    private val destinations = DestinationTracker()
    private val activities = ActivityNavigation(::report)
    private val controllers = ControllerNavigation(::report)
    private var fragments: FragmentNavigation? = null
    private var routes: ViewRouteResolver? = null

    private fun viewRoutes(): ViewRouteResolver {
        val existing = routes
        if (existing != null) return existing
        val created = ViewRouteResolver(
            destinations,
            fragmentRoute = { view -> fragments?.routeRootedAt(view) },
            visibleFragmentRoot = { activity -> fragments?.visibleRouteRoot(activity) },
        )
        routes = created
        return created
    }

    val routesAccessor: ViewRouteResolver
        get() = viewRoutes()

    fun resetForTests() {
        if (installed) {
            application?.unregisterActivityLifecycleCallbacks(this)
            installed = false
            application = null
        }
        recording = null
        frameScheduled = false
        frameScheduler = ChoreographerFrames()
        destinations.resetForTests()
        fragments?.unregisterAll()
        fragments = null
        routes = null
        NavigationProcessState.resetForTests()
    }

    /** Aligns fragment settling with the adapter's frame scheduler (unit tests). */
    fun setFrameSchedulerForTests(scheduler: FrameScheduler) {
        frameScheduler = scheduler
    }

    fun ensureInstalled(app: Application) {
        if (installed) return
        // `trackNavigation` before installation records controller stacks
        // with no activity resume or destroy seen for their hosts, so they
        // may be covered or finished: discard them. The next destination
        // change pushes onto an empty stack.
        controllers.forgetAll()
        application = app
        viewRoutes()
        fragments =
            if (OptionalAndroidx.fragment) {
                FragmentNavigation(activities, destinations, ::report, requestFrame = ::requestFrame)
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

    private fun requestFrame() {
        if (frameScheduled) return
        frameScheduled = true
        frameScheduler.postFrame {
            frameScheduled = false
            fragments?.flush()
        }
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
            val hostRoute = ensureEntry(activity).instanceId
            val navigatorId = ControllerNavigation.navigatorIdFor(hostRoute)
            val routeKey =
                destinations.routeKey(activity, current.route, current.destinationId)
                    ?: ControllerNavigation.TYPE
            controllers.onDestinationChanged(
                navigatorId,
                navigatorIdOf(activity),
                hostRoute,
                current,
                routeKey,
                previous,
            )
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
