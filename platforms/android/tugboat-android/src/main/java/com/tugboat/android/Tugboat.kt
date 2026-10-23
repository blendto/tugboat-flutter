package com.tugboat.android

import android.app.Application
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.navigation.NavController
import com.tugboat.android.engine.EngineTransport
import com.tugboat.android.engine.JniEngineTransport
import com.tugboat.android.evidence.EvidenceRecorder
import com.tugboat.android.sdk.NavigationTracking
import com.tugboat.android.sdk.SessionMessages
import com.tugboat.android.sdk.TugboatRuntime

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
 *     }
 * }
 * ```
 *
 * - Call [start] once per process, from `Application.onCreate`: activities
 *   created before it are not observed. After [stop], a new [start] observes
 *   each activity from its next resume.
 * - Every method may be called from any thread; the work runs on the main
 *   thread in call order.
 * - Nothing here throws into the app. A failure is logged (tag `Tugboat`)
 *   and capture stops; the app keeps running.
 */
object Tugboat {
    private const val TAG = "Tugboat"
    private val main: Handler by lazy { Handler(Looper.getMainLooper()) }

    // Main thread only.
    private var runtime: TugboatRuntime? = null
    private var sessionEpoch = 0
    private var userId: String? = null
    private var traitsInput: String? = null

    /**
     * Set on the main thread when [TugboatConfig.enabled] is `false` at [start];
     * cleared by an enabled [start]. Only [start] and [trackNavigation] read it:
     * the other APIs already record nothing without a runtime, and must keep
     * their state (user id, traits, hooks) for a later enabled [start].
     */
    @Volatile
    private var disabled = false

    /** JVM tests only: clears the kill-switch state, the kept identity, and the transport seam. */
    internal fun resetForTests() {
        disabled = false
        userId = null
        traitsInput = null
        openTransportForTesting = null
    }

    /** JVM tests only: replaces [JniEngineTransport.open] for [start]. */
    internal var openTransportForTesting: (() -> EngineTransport?)? = null

    /** The running session's evidence path; written on the main thread, read from any. */
    @Volatile
    private var evidence: EvidenceRecorder? = null

    /**
     * Starts capture and a session. Idempotent: while started, later calls
     * are ignored. Refuses to start (and logs which field) when the
     * collector's required `session_start` fields are missing, for example a
     * blank [AppInfo.version] or [AppInfo.buildNumber].
     */
    @JvmStatic
    fun start(application: Application, config: TugboatConfig) = onMain("start") {
        if (runtime != null) {
            Log.i(TAG, "Tugboat is already started")
            return@onMain
        }
        if (!config.enabled) {
            disabled = true
            Log.i(TAG, "Tugboat disabled by config")
            return@onMain
        }
        disabled = false
        val transport = openTransportForTesting ?: { JniEngineTransport.open() }
        val started = TugboatRuntime.start(application, config, sessionEpoch++, openTransport = transport) ?: return@onMain
        runtime = started
        evidence = started.evidence
        // A new engine starts without a user id, so only a set one is sent.
        userId?.let(started::setUserId)
        traitsInput?.let(started::setTraits)
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
     */
    @JvmStatic
    fun stop() = onMain("stop") {
        evidence = null
        runtime?.stop()
        runtime = null
    }

    /**
     * Tracks [navController]: its destinations become route keys for its
     * activity (route pattern without arguments, else the id's resource name)
     * and `route_change`s on a navigator nested under the activity's.
     * Optional; needs `androidx.navigation` in the app. Call once per
     * controller. Destinations shown before the first [start] are not
     * seeded into its session: the first change after it is a push.
     *
     * Call [start] before this when you use [TugboatConfig.enabled]: a call
     * before any [start] cannot know the config, so it attaches the listener
     * (it records nothing until an enabled [start]).
     */
    @JvmStatic
    fun trackNavigation(navController: NavController) = onMain("trackNavigation") {
        if (disabled) return@onMain
        NavigationTracking.track(navController) { activity, current, previous ->
            com.tugboat.android.views.navigation.NavigationObservation.onNavDestination(
                activity,
                current,
                previous,
            )
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
     * nothing when [route] is null or blank, or Tugboat is not started,
     * stopped, or disabled.
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
