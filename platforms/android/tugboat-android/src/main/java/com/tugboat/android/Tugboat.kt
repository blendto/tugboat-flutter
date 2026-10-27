package com.tugboat.android

import android.app.Application
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.navigation.NavController
import com.tugboat.android.engine.EngineTransport
import com.tugboat.android.engine.JniEngineTransport
import com.tugboat.android.evidence.EvidenceRecorder
import com.tugboat.android.sdk.LaunchCorrelation
import com.tugboat.android.sdk.LifecycleSnapshot
import com.tugboat.android.sdk.NavigationTracking
import com.tugboat.android.sdk.SessionMessages
import com.tugboat.android.sdk.TugboatRuntime
import com.tugboat.android.views.navigation.NavigationObservation

/**
 * The Tugboat Android SDK (native SDK note section 3).
 *
 * ```kotlin
 * class App : Application() {
 *     override fun onCreate() {
 *         super.onCreate()
 *         Tugboat.start(this, TugboatConfig(
 *             collector = CollectorConfig(baseUrl, apiKey),
 *             app = AppInfo(name, version, buildNumber, appId, installationId),
 *         ))
 *         // Dormant until activated (TugboatConfig.enabled is false by default):
 *         Tugboat.activate(activationRequestId = "request-1")
 *     }
 * }
 * ```
 *
 * The lifecycle matches Flutter's `TugboatReplay`: [TugboatConfig.enabled]
 * (default `false`) starts a session at [start]; otherwise the SDK is
 * [TugboatLifecycleState.DORMANT] until [activate], and [deactivate] returns
 * it there. [lifecycleState], [isActivated], and [activationRequestId] mirror
 * Flutter's getters.
 *
 * - Call [start] once per process, from `Application.onCreate`: activities
 *   created before it are not observed. A session that starts later (an
 *   [activate], or a [start] after [stop]) attaches at once to the
 *   activities created since the first [start], including one already
 *   resumed.
 * - Every method may be called from any thread; the work runs on the main
 *   thread in call order. The lifecycle getters change at once on the
 *   calling thread, as in Flutter.
 * - Nothing here throws into the app. A failure is logged (tag `Tugboat`)
 *   and capture stops; the app keeps running.
 */
object Tugboat {
    private const val TAG = "Tugboat"
    private val main: Handler by lazy { Handler(Looper.getMainLooper()) }

    // Main thread only.
    private var application: Application? = null
    private var config: TugboatConfig? = null
    private var runtime: TugboatRuntime? = null
    /** The activation request id the running [runtime] sent on `session.start`. */
    private var runtimeActivationId: String? = null
    private var sessionEpoch = 0
    private var userId: String? = null
    private var traitsInput: String? = null

    /**
     * The lifecycle request, as Flutter's `TugboatLifecycleNotifier`: changed
     * at once by [activate], [deactivate], and [stop] on the calling thread,
     * and applied on the main thread by [reconcile]. [requestEpoch] and
     * [captureOverride] are guarded by [lock]; [state] and [requestedId] are
     * written under it and are volatile for the getters.
     */
    private val lock = Any()
    private var requestEpoch = 0
    /** `true` after [activate], `false` after [deactivate], null to follow [TugboatConfig.enabled]. */
    private var captureOverride: Boolean? = null
    @Volatile
    private var state = TugboatLifecycleState.DORMANT
    @Volatile
    private var requestedId: String? = null

    /** JVM tests only: told every lifecycle state written, on the writing thread. */
    internal var lifecycleObserverForTesting: ((TugboatLifecycleState) -> Unit)? = null

    /** JVM tests only: forgets the config, the lifecycle request, the kept identity, and the transport seam. */
    internal fun resetForTests() {
        synchronized(lock) {
            requestEpoch++
            captureOverride = null
            requestedId = null
            state = TugboatLifecycleState.DORMANT
            evidence = null
        }
        runtime?.stop()
        runtime = null
        runtimeActivationId = null
        application = null
        config = null
        userId = null
        traitsInput = null
        openTransportForTesting = null
        lifecycleObserverForTesting = null
        LaunchCorrelation.resetForTests()
        NavigationObservation.resetForTests()
    }

    /** JVM tests only: replaces [JniEngineTransport.open] for [start]. */
    internal var openTransportForTesting: (() -> EngineTransport?)? = null

    /** The running session's evidence path; written under [lock] (or on the main thread by tests), read from any. */
    @Volatile
    private var evidence: EvidenceRecorder? = null

    /**
     * The capture lifecycle state (Flutter `TugboatReplay.lifecycleState`).
     * Readable from any thread.
     */
    @JvmStatic
    val lifecycleState: TugboatLifecycleState
        get() = state

    /**
     * The id of the last [activate] while it is in effect (Flutter
     * `TugboatReplay.activationRequestId`): null before any [activate], after
     * [deactivate] or [stop], and for a session [TugboatConfig.enabled]
     * started. Readable from any thread.
     */
    @JvmStatic
    val activationRequestId: String?
        get() = requestedId

    /**
     * Whether an [activate] is in effect: [activationRequestId] is set and
     * [lifecycleState] is starting, active, or stopping (Flutter
     * `TugboatReplay.isActivated`). Readable from any thread.
     */
    @JvmStatic
    val isActivated: Boolean
        get() = synchronized(lock) { requestedId != null && state != TugboatLifecycleState.DORMANT }

    /**
     * Stores [application] and [config] and installs process-scoped
     * observation (activity and fragment lifecycle callbacks, which record
     * navigation state only). With [TugboatConfig.enabled] a session starts
     * now, without an activation request id; otherwise the SDK stays
     * dormant (no engine, window callbacks, threads, or network) until
     * [activate]. An [activate] made before this applies here.
     *
     * Idempotent: while started (until [stop]), later calls are ignored. A
     * session refuses to start (and logs which field) when the collector's
     * required `session_start` fields are missing, for example a blank
     * [AppInfo.version] or [AppInfo.buildNumber]; the state then returns to
     * dormant.
     */
    @JvmStatic
    fun start(application: Application, config: TugboatConfig) = onMain("start") {
        if (this.config != null) {
            Log.i(TAG, "Tugboat is already started")
            return@onMain
        }
        this.application = application
        this.config = config
        NavigationObservation.ensureInstalled(application)
        reconcile()
    }

    /**
     * Starts a session whose `session.start` carries [activationRequestId]
     * (Flutter `TugboatReplay.activate`). The same id while starting or
     * active does nothing. A different id while a session runs ends it
     * (`session_end`) and starts a new one with the new id; the state goes
     * from active to starting, never stopping. Before [start] (also after
     * [stop]) the request is kept and the next [start] applies it, whatever
     * [TugboatConfig.enabled] says.
     *
     * A blank id still activates; `session.start` then omits it (Flutter
     * sends `""`).
     */
    @JvmStatic
    fun activate(activationRequestId: String) {
        guarded("activate") {
            synchronized(lock) {
                val sameRequest = requestedId == activationRequestId && captureOverride == true &&
                    (state == TugboatLifecycleState.STARTING || state == TugboatLifecycleState.ACTIVE)
                if (sameRequest) return@guarded
                requestEpoch++
                requestedId = activationRequestId
                captureOverride = true
                setState(TugboatLifecycleState.STARTING)
            }
            onMain("activate", ::reconcile)
        }
    }

    /**
     * Returns the SDK to dormant (Flutter `TugboatReplay.deactivate`).
     * Evidence is fenced at once on the calling thread: an event or network
     * call recorded after this returns is dropped. On the main thread the
     * session ends as [stop] ends it (`session_end`, delivered in the
     * background); the state is stopping until `session.end` is posted, then
     * dormant. A [TugboatConfig.enabled] config does not start a session
     * again until the next [activate]. Does nothing while dormant with no
     * activation request.
     */
    @JvmStatic
    fun deactivate() {
        guarded("deactivate") {
            synchronized(lock) {
                if (state == TugboatLifecycleState.DORMANT && requestedId == null) return@guarded
                requestEpoch++
                evidence = null
                requestedId = null
                captureOverride = false
                setState(TugboatLifecycleState.STOPPING)
            }
            onMain("deactivate", ::reconcile)
        }
    }

    /** The runtime user id stamped on later events; null clears it. Kept across [stop] and [start]. */
    @JvmStatic
    fun setUserId(id: String?) = onMain("setUserId") {
        userId = id
        runtime?.setUserId(id)
    }

    /**
     * Replaces the traits bag (JSON values: strings, numbers, booleans,
     * null, lists, maps). Kept across [stop] and [start]. A map JSON cannot
     * carry (NaN, infinities) is ignored and logged.
     */
    @JvmStatic
    fun setTraits(traits: Map<String, Any?>) {
        // Encoded now: the caller may change the map after this returns.
        val input = guarded("setTraits") { SessionMessages.traits(traits) } ?: return
        onMain("setTraits") {
            traitsInput = input
            runtime?.setTraits(input)
        }
    }

    /**
     * Ends the session and stops capture. The session's last events and
     * `session_end` are delivered in the background before the engine is
     * disposed (at most about 25 s when the collector is unreachable).
     *
     * Native only, and not Flutter's `TugboatReplay.disabled`: it also
     * forgets the config and clears any activation request, so an [activate]
     * made before it never restarts a session. An [activate] after it is kept
     * for the next [start]. Process-scoped observation stays installed.
     */
    @JvmStatic
    fun stop() {
        guarded("stop") {
            val epoch = synchronized(lock) {
                requestEpoch++
                evidence = null
                requestedId = null
                captureOverride = null
                if (state != TugboatLifecycleState.DORMANT) setState(TugboatLifecycleState.STOPPING)
                requestEpoch
            }
            onMain("stop") {
                endSession()
                application = null
                config = null
                markDormant(epoch)
            }
        }
    }

    /**
     * Tracks [navController]: its destinations become route keys for its
     * activity (route pattern without arguments, else the id's resource name)
     * and `route_change`s on a navigator nested under the activity's.
     * Optional; needs `androidx.navigation` in the app. Call once per
     * controller, after [start]: its back stack is kept while dormant and
     * seeds each session. Destinations shown before the first [start] are
     * not: the first change after it is a push.
     */
    @JvmStatic
    fun trackNavigation(navController: NavController) = onMain("trackNavigation") {
        NavigationTracking.track(navController) { activity, current, previous ->
            NavigationObservation.onNavDestination(activity, current, previous)
        }
    }

    /**
     * A hook for your app's own events (`external_event` evidence):
     *
     * ```kotlin
     * val events = Tugboat.eventHook(source = "analytics", parameterPolicy = ParameterPolicy.allowList(setOf("method")))
     * events.record("USER_LOGIN", mapOf("method" to "email"))
     * ```
     *
     * [source] names where the events come from (for example your analytics
     * SDK). [parameterPolicy] is [ParameterPolicy.allowAll] by default, which
     * keeps every value within the engine's limits. The hook can be made
     * before [start] and kept across sessions: each record goes to the
     * session running when it is called, and is ignored while none is.
     */
    @JvmStatic
    @JvmOverloads
    fun eventHook(source: String? = null, parameterPolicy: ParameterPolicy = ParameterPolicy.allowAll): EventHook =
        EventHook(source, parameterPolicy) { evidence }

    /**
     * Begins one logical HTTP call (`network_call` evidence); finish it with
     * [NetworkCall.complete] or [NetworkCall.fail]:
     *
     * ```kotlin
     * val call = Tugboat.beginNetworkCall(method = "GET", route = "/orders/123")
     * call.complete(statusCode = 200)
     * ```
     *
     * [route] is a path you choose: an absolute path, which may hold dynamic
     * ids, never a full URL or a query (the engine drops a route with a
     * scheme, query, fragment, percent-encoding, or whitespace). The start
     * time is taken now, on the calling thread. Returns a call that records
     * nothing when [route] is null or blank, or no session is recording
     * (dormant, deactivated, or stopped).
     */
    @JvmStatic
    fun beginNetworkCall(method: String, route: String?): NetworkCall {
        return guarded("beginNetworkCall") { evidence?.beginNetworkCall(method, route) } ?: NetworkCall.NOOP
    }

    /** Whether a call begun now would be recorded (`TugboatAdapters.isAcceptingEvidence`). */
    internal val isAcceptingEvidence: Boolean
        get() = evidence?.isAccepting == true

    /** Replaces the evidence path, returning the previous one (`TugboatAdapters.tapEvidenceForTesting` only). */
    internal fun swapEvidence(recorder: EvidenceRecorder?): EvidenceRecorder? {
        val previous = evidence
        evidence = recorder
        return previous
    }

    /**
     * Main thread: moves the runtime toward the lifecycle request (Flutter's
     * activation gate). Ends a session that is no longer wanted or carries
     * another activation request id, then starts one when wanted and
     * [start] has stored a config.
     */
    private fun reconcile() {
        val (epoch, wanted, id) = synchronized(lock) {
            Triple(requestEpoch, captureOverride ?: (config?.enabled == true), requestedId)
        }
        if (runtime != null && (!wanted || runtimeActivationId != id)) endSession()
        if (!wanted) return markDormant(epoch)
        if (runtime != null) return markActive(epoch)
        val app = application ?: return
        val cfg = config ?: return
        markStarting(epoch)
        startSession(app, cfg, epoch, id)
    }

    private fun startSession(application: Application, config: TugboatConfig, epoch: Int, id: String?) {
        val transport = openTransportForTesting ?: { JniEngineTransport.open() }
        val started = TugboatRuntime.start(
            application,
            config,
            sessionEpoch++,
            activationRequestId = id,
            lifecycle = { LifecycleSnapshot(state, requestedId) },
            openTransport = transport,
        )
        if (started == null) return markFailed(epoch)
        runtime = started
        runtimeActivationId = id
        // A deactivate or stop since [epoch] fenced evidence: keep it fenced
        // (its own reconcile ends this session next).
        synchronized(lock) { if (requestEpoch == epoch) evidence = started.evidence }
        // A new engine starts without a user id, so only a set one is sent.
        userId?.let(started::setUserId)
        traitsInput?.let(started::setTraits)
        markActive(epoch)
    }

    /** Main thread: fences evidence and stops the runtime (`session.end` is posted before this returns). */
    private fun endSession() {
        val ending = runtime ?: return
        synchronized(lock) { evidence = null }
        runtime = null
        runtimeActivationId = null
        ending.stop()
    }

    // The transitions of Flutter's `TugboatLifecycleNotifier` (`markStarting`,
    // `markActive`, `markDormant`): each applies only while [epoch] is the
    // latest request.

    private fun markStarting(epoch: Int) {
        synchronized(lock) {
            if (epoch == requestEpoch && state == TugboatLifecycleState.DORMANT) setState(TugboatLifecycleState.STARTING)
        }
    }

    private fun markActive(epoch: Int) {
        synchronized(lock) {
            val starting = state == TugboatLifecycleState.STARTING || state == TugboatLifecycleState.ACTIVE
            if (epoch == requestEpoch && starting) setState(TugboatLifecycleState.ACTIVE)
        }
    }

    private fun markDormant(epoch: Int) {
        synchronized(lock) {
            if (epoch == requestEpoch && captureOverride != true) setState(TugboatLifecycleState.DORMANT)
        }
    }

    /** The session could not start (logged by [TugboatRuntime.start]); a later [activate] retries. */
    private fun markFailed(epoch: Int) {
        synchronized(lock) {
            if (epoch == requestEpoch) setState(TugboatLifecycleState.DORMANT)
        }
    }

    /** Under [lock]. */
    private fun setState(next: TugboatLifecycleState) {
        state = next
        lifecycleObserverForTesting?.invoke(next)
    }

    private fun onMain(what: String, block: () -> Unit) {
        guarded(what) {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                block()
            } else {
                main.post { guarded(what, block) }
            }
        }
    }

    /** Runs [block]; anything it throws is logged, never rethrown. */
    internal fun <T> guarded(what: String, block: () -> T): T? =
        try {
            block()
        } catch (failure: Throwable) {
            try {
                Log.e(TAG, "Tugboat $what failed", failure)
            } catch (_: Throwable) {
                // Logging must not throw into the app either.
            }
            null
        }
}
