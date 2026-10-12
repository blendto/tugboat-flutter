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
import com.tugboat.android.views.identity.AnchorResolver
import com.tugboat.android.views.identity.AndroidResourceNames
import com.tugboat.android.views.input.GestureConfig
import com.tugboat.android.views.mask.WindowMaskResult
import com.tugboat.android.views.mask.WindowMasks
import com.tugboat.android.views.navigation.ActivityNavigation
import com.tugboat.android.views.navigation.DestinationTracker
import com.tugboat.android.views.navigation.FragmentNavigation
import com.tugboat.android.views.navigation.NavigationChange
import com.tugboat.android.views.navigation.RouteRoots
import com.tugboat.android.views.navigation.ViewRouteResolver
import java.util.WeakHashMap

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
) : Application.ActivityLifecycleCallbacks {
    private val clock = FactClock(hostClock)
    private val batcher = FactBatcher(sink, frames)
    private val destinations = DestinationTracker()
    private val roots = RouteRoots()
    private val anchors = AnchorResolver(AndroidResourceNames(application.resources), ViewRouteResolver(roots, destinations))
    private val activities = ActivityNavigation(::reportNavigation)
    private val fragments =
        if (OptionalAndroidx.fragment) {
            FragmentNavigation(activities, destinations, roots, ::reportNavigation, batcher::requestFrame)
        } else {
            null
        }
    private val sessions = WeakHashMap<Activity, WindowSession>()
    private var started = false

    init {
        batcher.onFrame(::onFrame)
    }

    fun start() {
        if (started) return
        started = true
        application.registerActivityLifecycleCallbacks(this)
    }

    /** Detaches from every window and posts what is pending. */
    fun stop() {
        if (!started) return
        started = false
        application.unregisterActivityLifecycleCallbacks(this)
        sessions.values.toList().forEach(WindowSession::detach)
        sessions.clear()
        batcher.flush()
    }

    /** Mask rectangles for [window] under `allTextAndMedia`; called on the main thread per `capture.request`. */
    fun masks(window: Window): WindowMaskResult = WindowMasks.compute(window)

    /** The `trackNavigation` hook: [activity]'s Jetpack Navigation destination changed. */
    fun onDestinationChanged(activity: Activity, route: String?, destinationId: Int) =
        AdapterGuard.run("destination changed") { destinations.onDestinationChanged(activity, route, destinationId) }

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
            if (activity.isFinishing) {
                fragments?.forget(activity)
                destinations.clear(activity)
            }
            activities.onDestroyed(activity)
        }

    override fun onActivityStarted(activity: Activity) = Unit

    override fun onActivityPaused(activity: Activity) = Unit

    override fun onActivityStopped(activity: Activity) = Unit

    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit

    private fun session(activity: Activity): WindowSession =
        sessions.getOrPut(activity) {
            WindowSession(activity, clock, gesture, anchors, batcher::add, batcher::requestFrame)
        }

    private fun reportNavigation(change: NavigationChange) = batcher.add(change.toFact(clock.now()))

    private fun onFrame() {
        fragments?.flush()
        sessions.values.toList().forEach(WindowSession::onFrame)
    }
}
