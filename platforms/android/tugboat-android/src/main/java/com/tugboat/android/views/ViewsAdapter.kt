package com.tugboat.android.views

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.view.Window
import com.tugboat.android.host.HostClock
import com.tugboat.android.host.SystemHostClock
import com.tugboat.android.views.facts.ChoreographerFrames
import com.tugboat.android.views.facts.FactBatcher
import com.tugboat.android.views.facts.FactClock
import com.tugboat.android.views.facts.FactSink
import com.tugboat.android.views.facts.FrameScheduler
import com.tugboat.android.views.facts.ViewsFact
import com.tugboat.android.views.identity.AnchorResolver
import com.tugboat.android.views.identity.AndroidResourceNames
import com.tugboat.android.views.input.GestureConfig
import com.tugboat.android.views.mask.WindowMaskResult
import com.tugboat.android.views.mask.WindowMasks
import com.tugboat.android.views.navigation.ActivityNavigation
import com.tugboat.android.views.navigation.ControllerNavigation
import com.tugboat.android.views.navigation.DestinationTracker
import com.tugboat.android.views.navigation.FragmentNavigation
import com.tugboat.android.views.navigation.NavEntry
import com.tugboat.android.views.navigation.NavigationChange
import com.tugboat.android.views.navigation.ViewRouteResolver

/**
 * The Android Views toolkit adapter (native SDK note section 5): it turns
 * activity windows into engine facts and answers mask queries. It owns no
 * engine state; facts leave once per frame through [sink]
 * (`EngineHost::postBatch`).
 *
 * Start it from `Application.onCreate`: activities that already exist when
 * [start] runs are not observed. Main thread only. Internal: the public
 * `Tugboat` facade, `trackNavigation`, and capture wiring are the SDK slice.
 */
internal class ViewsAdapter(
    private val application: Application,
    sink: FactSink,
    hostClock: HostClock = SystemHostClock,
    frames: FrameScheduler = ChoreographerFrames(),
    /** Send `gesture.toEngineJson()` in `engine.configure` so engine and adapter agree on taps. */
    val gesture: GestureConfig = GestureConfig.from(application),
    /**
     * Engine-wiring gate. `navigation` is a phase 3d engine message: before 3d
     * a real engine rejects it, and with it the whole batch. Navigation is
     * still tracked (route keys need it); only its facts are held back.
     * TODO(ADR 0009 phase 3d): default to true once the engine accepts `navigation`.
     */
    private val postNavigationFacts: Boolean = false,
) : Application.ActivityLifecycleCallbacks {
    private val clock = FactClock(hostClock)
    private val batcher = FactBatcher(sink, frames, ::onFrame)
    private val destinations = DestinationTracker()
    private val routes = ViewRouteResolver(destinations) { view -> fragments?.routeRootedAt(view) }
    private val anchors = AnchorResolver(AndroidResourceNames(application.resources), routes)
    private val activities = ActivityNavigation(::reportNavigation)
    private val controllers = ControllerNavigation(::reportNavigation)
    private val fragments =
        if (OptionalAndroidx.fragment) {
            FragmentNavigation(activities, destinations, ::reportNavigation, batcher::requestFrame)
        } else {
            null
        }
    private val sessions = HashMap<Activity, WindowSession>()
    private var started = false

    fun start() = AdapterGuard.run("start") {
        if (started) return@run
        started = true
        application.registerActivityLifecycleCallbacks(this)
    }

    /** Posts what is pending, then detaches everywhere; nothing is emitted after it. */
    fun stop() = AdapterGuard.run("stop") {
        if (!started) return@run
        batcher.flush()
        started = false
        application.unregisterActivityLifecycleCallbacks(this)
        fragments?.unregisterAll()
        sessions.values.toList().forEach(WindowSession::detach)
        sessions.clear()
    }

    /** Fragment navigator ids currently tracked; for tests. */
    val fragmentNavigatorIds: Set<String>
        get() = fragments?.navigatorIds.orEmpty()

    /** Mask rectangles for [window] under `allTextAndMedia`; called on the main thread per `capture.request`. */
    fun masks(window: Window): WindowMaskResult = WindowMasks.compute(window)

    /**
     * [activity]'s Jetpack Navigation destination changed: route keys only.
     * The SDK facade uses [onNavDestination], which also reports navigation.
     * The route pattern loses its arguments ([com.tugboat.android.views.navigation.RoutePattern]),
     * so Views and Compose anchors and navigation facts share one route key.
     */
    fun onDestinationChanged(activity: Activity, route: String?, destinationId: Int) =
        AdapterGuard.run("destination changed") { destinations.onDestinationChanged(activity, route, destinationId) }

    /**
     * The `trackNavigation` hook with the back stack: [current] is the
     * controller's new current entry, [previous] the one below it. Updates the
     * route key ([onDestinationChanged]) and reports the change as a
     * `navigation` fact on the controller's navigator, nested under
     * [activity]'s ([ControllerNavigation]).
     */
    fun onNavDestination(activity: Activity, current: NavEntry, previous: NavEntry?) =
        AdapterGuard.run("nav destination") {
            destinations.onDestinationChanged(activity, current.route, current.destinationId)
            val navigatorId = ControllerNavigation.navigatorIdFor(activities.ensureEntry(activity).instanceId)
            val routeKey = destinations.routeKey(activity, current.route, current.destinationId) ?: ControllerNavigation.TYPE
            controllers.onDestinationChanged(navigatorId, activities.navigatorIdOf(activity), current, routeKey, previous)
        }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) =
        AdapterGuard.run("activity created") {
            activities.onCreated(activity)
            fragments?.register(activity)
            session(activity).ensureAttached()
        }

    override fun onActivityResumed(activity: Activity) =
        AdapterGuard.run("activity resumed") {
            session(activity).ensureAttached()
            activities.onResumed(activity)
        }

    override fun onActivityDestroyed(activity: Activity) =
        AdapterGuard.run("activity destroyed") {
            sessions.remove(activity)?.detach()
            fragments?.unregister(activity)
            if (activity.isFinishing) {
                fragments?.forget(activity)
                destinations.clear(activity)
                activities.entryOf(activity)?.let { controllers.forget(ControllerNavigation.navigatorIdFor(it.instanceId)) }
            }
            activities.onDestroyed(activity)
        }

    override fun onActivityStarted(activity: Activity) = Unit

    override fun onActivityPaused(activity: Activity) = Unit

    override fun onActivityStopped(activity: Activity) = Unit

    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit

    private fun session(activity: Activity): WindowSession =
        sessions.getOrPut(activity) {
            WindowSession(activity, clock, gesture, anchors, ::emit, batcher::requestFrame)
        }

    /** The only way facts reach the batcher: nothing after [stop]. */
    private fun emit(fact: ViewsFact) {
        if (started) batcher.add(fact)
    }

    private fun reportNavigation(change: NavigationChange) {
        if (postNavigationFacts) emit(change.toFact(clock.now()))
    }

    private fun onFrame() {
        fragments?.flush()
        sessions.values.toList().forEach(WindowSession::onFrame)
    }
}
