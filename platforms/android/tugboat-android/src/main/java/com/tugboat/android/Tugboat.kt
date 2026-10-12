package com.tugboat.android

import android.app.Application
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.navigation.NavController
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
        val started = TugboatRuntime.start(application, config, sessionEpoch++) ?: return@onMain
        runtime = started
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
        runtime?.stop()
        runtime = null
    }

    /**
     * Tracks [navController]: its destinations become route keys for its
     * activity (route pattern without arguments, else the id's resource name)
     * and `route_change`s on a navigator nested under the activity's.
     * Optional; needs `androidx.navigation` in the app. Call once per
     * controller.
     */
    @JvmStatic
    fun trackNavigation(navController: NavController) = onMain("trackNavigation") {
        NavigationTracking.track(navController) { activity, current, previous ->
            runtime?.onNavDestination(activity, current, previous)
        }
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

    private inline fun <T> guarded(what: String, block: () -> T): T? =
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
