package com.tugboat.android.views

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import android.view.ViewTreeObserver
import android.view.Window
import androidx.annotation.VisibleForTesting
import com.tugboat.android.host.HostClock
import com.tugboat.android.host.SceneWatchSink
import com.tugboat.android.host.SystemHostClock
import com.tugboat.android.views.facts.ChoreographerFrames
import com.tugboat.android.views.facts.FactBatcher
import com.tugboat.android.views.facts.FactTypes
import com.tugboat.android.views.facts.FactClock
import com.tugboat.android.views.facts.FactSink
import com.tugboat.android.views.facts.FrameScheduler
import com.tugboat.android.views.facts.ViewsFact
import com.tugboat.android.views.identity.AnchorResolver
import com.tugboat.android.adapter.TugboatAdapters
import com.tugboat.android.views.identity.AndroidResourceNames
import com.tugboat.android.views.identity.FallbackNames
import com.tugboat.android.views.input.FocusState
import com.tugboat.android.views.input.GestureConfig
import com.tugboat.android.views.inventory.SceneInventoryBuilder
import com.tugboat.android.views.inventory.SceneInventoryEmitter
import com.tugboat.android.views.mask.WindowMaskResult
import com.tugboat.android.views.mask.WindowMasks
import com.tugboat.android.views.navigation.ActivityNavigation
import com.tugboat.android.views.navigation.NavigationChange
import com.tugboat.android.views.navigation.NavigationObservation
import com.tugboat.android.views.navigation.NavigationProcessState
import com.tugboat.android.views.overlay.withOverlayWindow
import org.json.JSONObject

/**
 * The Android Views toolkit adapter (native SDK note section 5): it turns
 * activity windows into engine facts and answers mask queries. It owns no
 * engine state; facts leave once per frame through [sink]
 * (`EngineHost::postBatch`).
 *
 * [start] attaches to the activities process-scoped observation
 * ([NavigationObservation]) has seen since it was installed, the resumed
 * one as if it had just resumed; activities created before that are
 * observed from their next resume. Main thread only. Internal: the public
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
    /** `View::getLocationOnScreen` for dialog-window offsets; a seam for tests. */
    private val locateOnScreen: (View, IntArray) -> Unit = View::getLocationOnScreen,
) : Application.ActivityLifecycleCallbacks, SceneWatchSink {
    init {
        NavigationObservation.ensureInstalled(application)
    }

    private val clock = FactClock(hostClock)
    private val batcher = FactBatcher(sink, frames, ::onFrame)
    private val routes = NavigationObservation.routesAccessor
    private val names = FallbackNames(AndroidResourceNames(application.resources)) { TugboatAdapters.viewNameProvider }
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
    @VisibleForTesting
    internal val focusState = FocusState()
    private var started = false
    private var windowCallbacksRegistered = false

    /** The window whose draws the re-sample watch reports and whose inventory a sample answers with. Main thread. */
    @VisibleForTesting
    internal var sampleWindow: () -> Window? = { null }

    /** True while the engine's re-sample watch is armed (`scene.watch`); any thread reads it. */
    @Volatile
    internal var watchArmed = false
        private set
    private val main = Handler(Looper.getMainLooper())
    private var drawObserver: ViewTreeObserver? = null
    /** One instance for the adapter's lifetime: removing before adding leaves exactly one on any observer. */
    private val drawListener = ViewTreeObserver.OnDrawListener { onWatchedDraw() }
    private var lastDrawReportMs = 0L

    /** Draw callbacks received, before the throttle; a seam for tests. */
    @VisibleForTesting
    internal var drawCallbacks = 0

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
        attachLiveActivities()
    }

    /**
     * A session that starts after its activities (an `activate` while one is
     * resumed, or a start after `stop`) attaches to them now, as their create
     * and resume callbacks would have.
     */
    private fun attachLiveActivities() {
        val live = NavigationObservation.liveActivities()
        live.forEach { session(it).ensureAttached() }
        NavigationObservation.resumedActivity()?.let { onActivityResumed(it) }
        // Dialogs already up (after the resume, so a focused dialog stays the active window).
        live.forEach { activity -> AdapterGuard.run("adopt dialogs") { sessions[activity]?.adoptDialogs() } }
    }

    /**
     * Posts what is pending, then detaches window observers. Process-scoped
     * navigation observation keeps updating stacks while stopped; nothing is
     * emitted until the next [start], which attaches again.
     */
    fun stop() = AdapterGuard.run("stop") {
        if (!started) return@run
        batcher.flush()
        started = false
        watchArmed = false
        detachDrawListener()
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
        trigger: String? = null,
        window: () -> Window?,
    ) {
        if (!emitSceneInventory) return
        mainThread(Runnable { window()?.let { onCapturedFrame(it, structureSignature, hasRegionHosts, trigger) } })
    }

    /**
     * A capture of [window] completed: emits the visible route's
     * `scene.inventory` when [emitSceneInventory] is on
     * ([SceneInventoryEmitter]). Main thread.
     */
    fun onCapturedFrame(window: Window, structureSignature: String, hasRegionHosts: Boolean, trigger: String? = null) =
        AdapterGuard.run("scene inventory") {
            if (!emitSceneInventory || !started) return@run
            // A tap, gesture or scroll moment, and any frame while no watch is armed, must reach the engine.
            val mayReuse = watchArmed && trigger !in MOMENT_TRIGGERS
            inventory.onCapturedFrame(window, structureSignature, hasRegionHosts, trigger, mayReuse)
        }

    /** `scene.watch` (engine thread): report drawn frames of the sample window while armed. */
    override fun onSceneWatch(armed: Boolean) {
        watchArmed = armed && emitSceneInventory
        main.post {
            AdapterGuard.run("scene watch") {
                if (watchArmed && started) attachDrawListener() else detachDrawListener()
            }
        }
    }

    /** `scene.sample` (engine thread): answer with the visible route's inventory. */
    override fun onSceneSample() {
        if (!emitSceneInventory) return
        main.post {
            AdapterGuard.run("scene sample") {
                if (started && watchArmed) {
                    rebindDrawListener()
                    sampleWindow()?.let { inventory.onSample(it) }
                }
            }
        }
    }

    /** Moves the draw listener to the sample window's tree when it is not on it (a recreated activity). */
    private fun rebindDrawListener() {
        if (!started || !watchArmed) return
        val current = sampleWindow()?.decorView?.viewTreeObserver
        if (current != null && current.isAlive && current !== drawObserver) attachDrawListener()
    }

    private fun attachDrawListener() {
        detachDrawListener()
        val observer = sampleWindow()?.decorView?.viewTreeObserver?.takeIf { it.isAlive } ?: return
        observer.removeOnDrawListener(drawListener)
        observer.addOnDrawListener(drawListener)
        drawObserver = observer
    }

    private fun detachDrawListener() {
        val observer = drawObserver
        drawObserver = null
        if (observer != null && observer.isAlive) observer.removeOnDrawListener(drawListener)
    }

    /** A frame of the watched window was drawn: `scene.frame`, at most once per [WATCH_FRAME_INTERVAL_MS]. */
    private fun onWatchedDraw() {
        drawCallbacks++
        if (!watchArmed || !started) return
        val now = SystemClock.uptimeMillis()
        if (now - lastDrawReportMs < WATCH_FRAME_INTERVAL_MS) return
        lastDrawReportMs = now
        emit(ViewsFact(FactTypes.SCENE_FRAME, JSONObject(), clock.now()))
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) =
        AdapterGuard.run("activity created") { session(activity).ensureAttached() }

    override fun onActivityResumed(activity: Activity) =
        AdapterGuard.run("activity resumed") {
            session(activity).apply {
                ensureAttached()
                onWindowActive()
            }
            // A recreated activity has a new window: the watch follows it.
            if (watchArmed) main.post { AdapterGuard.run("scene watch rebind") { rebindDrawListener() } }
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
            WindowSession(activity, clock, gesture, anchors, ::emit, batcher::requestFrame, focusState, locateOnScreen)
        }

    /** Live dialog-window sessions of [activity]; for tests. */
    @VisibleForTesting
    fun dialogSessionCount(activity: Activity): Int = sessions[activity]?.dialogSessionCount ?: 0

    private fun emit(fact: ViewsFact) {
        if (started) batcher.add(fact)
    }

    private fun reportNavigation(change: NavigationChange) {
        if (!postNavigationFacts) return
        // The host names its screens: the activity is not a route.
        if (TugboatAdapters.hostNamesScreens && ActivityNavigation.isActivityNavigator(change.navigatorId)) return
        emit(change.toFact(clock.now()))
    }

    private fun emitSessionStartSeeds() {
        if (!postNavigationFacts) return
        val now = clock.now()
        NavigationProcessState.sessionStartSnapshots()
            .filterNot { TugboatAdapters.hostNamesScreens && ActivityNavigation.isActivityNavigator(it.navigatorId) }
            .forEach { snapshot -> emit(snapshot.toFact(now)) }
    }

    private fun onFrame() {
        NavigationObservation.flushFragments()
        sessions.values.toList().forEach(WindowSession::onFrame)
    }

    private companion object {
        /** The engine asks for at most one `scene.frame` per 100 ms (stateful-engine.md section 4.3.2). */
        const val WATCH_FRAME_INTERVAL_MS = 100L

        /** Captures taken for an interaction: the engine's re-sample is labelled by them. */
        val MOMENT_TRIGGERS = setOf("tap", "gesture", "scroll")
    }
}
