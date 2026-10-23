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
import com.tugboat.android.views.input.FocusState
import com.tugboat.android.views.input.GestureConfig
import com.tugboat.android.views.inventory.SceneInventoryBuilder
import com.tugboat.android.views.inventory.SceneInventoryEmitter
import com.tugboat.android.views.mask.WindowMaskResult
import com.tugboat.android.views.mask.WindowMasks
import com.tugboat.android.views.navigation.NavigationChange
import com.tugboat.android.views.navigation.NavigationObservation
import com.tugboat.android.views.navigation.NavigationProcessState
import com.tugboat.android.views.overlay.withOverlayWindow

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
    /** `TugboatConfig.emitSceneInventory`: [onCapturedFrame] emits `scene.inventory` ([SceneInventoryEmitter]). */
    private val emitSceneInventory: Boolean = false,
    /** Told at the start of each scene inventory walk; a seam for tests. */
    onInventoryWalk: () -> Unit = {},
) : Application.ActivityLifecycleCallbacks {
    init {
        NavigationObservation.ensureInstalled(application)
    }

    private val clock = FactClock(hostClock)
    private val batcher = FactBatcher(sink, frames, ::onFrame)
    private val routes = NavigationObservation.routesAccessor
    private val names = AndroidResourceNames(application.resources)
    private val anchors = AnchorResolver(names, routes)
    private val inventory = SceneInventoryEmitter(
        routes,
        SceneInventoryBuilder(names, routes, anchors, onWalk = onInventoryWalk),
        clock,
    ) { fact ->
        if (started) batcher.add(fact)
        started
    }
    private val sessions = HashMap<Activity, WindowSession>()

    /** Focus is app-wide: every window reports against the same last kind. */
    private val focusState = FocusState()
    private var started = false
    private var windowCallbacksRegistered = false

    fun start() = AdapterGuard.run("start") {
        if (started) return@run
        registerWindowCallbacks()
        started = true
        // Settle fragment changes made while stopped before seeding, and
        // seed before recording, so a pre-start removal is never a live pop.
        NavigationObservation.flushFragments()
        emitSessionStartSeeds()
        // Post the seeds now, not at the next frame: the runtime's lifecycle
        // replay right after start() makes the engine request a capture, and
        // its route context must already be the seeded one.
        batcher.flush()
        if (postNavigationFacts) {
            NavigationObservation.setRecording(::reportNavigation)
        }
    }

    /**
     * Posts what is pending, then detaches window observers. Process-scoped
     * navigation observation keeps updating stacks while stopped; nothing is
     * emitted until the next [start].
     */
    fun stop() = AdapterGuard.run("stop") {
        if (!started) return@run
        batcher.flush()
        started = false
        NavigationObservation.setRecording(null)
        unregisterWindowCallbacks()
        sessions.values.toList().forEach(WindowSession::detach)
        sessions.clear()
    }

    private fun registerWindowCallbacks() {
        if (windowCallbacksRegistered) return
        application.registerActivityLifecycleCallbacks(this)
        windowCallbacksRegistered = true
    }

    private fun unregisterWindowCallbacks() {
        if (!windowCallbacksRegistered) return
        application.unregisterActivityLifecycleCallbacks(this)
        windowCallbacksRegistered = false
    }

    /** Mask rectangles for [window] under `allTextAndMedia`; called on the main thread per `capture.request`. */
    fun masks(window: Window): WindowMaskResult {
        val masks = WindowMasks.compute(window)
        val activity = window.context as? Activity ?: return masks
        val session = sessions[activity] ?: return masks
        return if (session.overlayAtCapture(window)) masks.withOverlayWindow() else masks
    }

    /**
     * Any thread: a capture completed with [structureSignature] and
     * [hasRegionHosts] (from its masks' walk). When [emitSceneInventory] is
     * on, posts [onCapturedFrame] to [mainThread] for the window [window]
     * gives there (main-thread state, read when the walk runs); otherwise
     * does nothing.
     */
    fun onCaptureCompleted(
        structureSignature: String,
        hasRegionHosts: Boolean,
        mainThread: (Runnable) -> Boolean,
        window: () -> Window?,
    ) {
        if (!emitSceneInventory) return
        mainThread(Runnable { window()?.let { onCapturedFrame(it, structureSignature, hasRegionHosts) } })
    }

    /**
     * A capture of [window] completed: emits the visible route's
     * `scene.inventory` when [emitSceneInventory] is on
     * ([SceneInventoryEmitter]). Main thread.
     */
    fun onCapturedFrame(window: Window, structureSignature: String, hasRegionHosts: Boolean) =
        AdapterGuard.run("scene inventory") {
            if (emitSceneInventory && started) inventory.onCapturedFrame(window, structureSignature, hasRegionHosts)
        }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) =
        AdapterGuard.run("activity created") { session(activity).ensureAttached() }

    override fun onActivityResumed(activity: Activity) =
        AdapterGuard.run("activity resumed") {
            session(activity).apply {
                ensureAttached()
                onWindowActive()
            }
        }

    override fun onActivityDestroyed(activity: Activity) =
        AdapterGuard.run("activity destroyed") { sessions.remove(activity)?.detach() }

    override fun onActivityStarted(activity: Activity) = Unit

    override fun onActivityPaused(activity: Activity) =
        AdapterGuard.run("activity paused") { sessions[activity]?.onActivityPaused() }

    override fun onActivityStopped(activity: Activity) = Unit

    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit

    private fun session(activity: Activity): WindowSession =
        sessions.getOrPut(activity) {
            WindowSession(activity, clock, gesture, anchors, ::emit, batcher::requestFrame, focusState)
        }

    private fun emit(fact: ViewsFact) {
        if (started) batcher.add(fact)
    }

    private fun reportNavigation(change: NavigationChange) {
        if (!postNavigationFacts) return
        emit(change.toFact(clock.now()))
    }

    private fun emitSessionStartSeeds() {
        if (!postNavigationFacts) return
        val now = clock.now()
        NavigationProcessState.sessionStartSnapshots().forEach { snapshot ->
            emit(snapshot.toFact(now))
        }
    }

    private fun onFrame() {
        NavigationObservation.flushFragments()
        sessions.values.toList().forEach(WindowSession::onFrame)
    }
}
