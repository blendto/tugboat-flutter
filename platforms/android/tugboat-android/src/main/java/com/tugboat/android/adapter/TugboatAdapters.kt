package com.tugboat.android.adapter

import android.app.Application
import android.view.View
import com.tugboat.android.Tugboat
import com.tugboat.android.views.navigation.NavigationObservation
import com.tugboat.android.evidence.EngineEvidenceEncoder
import com.tugboat.android.evidence.EvidenceRecorder
import com.tugboat.android.host.HostClock
import com.tugboat.android.host.HostTime

/** What an HTTP-client adapter needs from the SDK besides the public network-call API. */
@TugboatAdapterApi
object TugboatAdapters {
    @Volatile
    internal var viewNameProvider: ((View) -> String?)? = null

    @Volatile
    internal var hostNamesScreens: Boolean = false

    @Volatile
    internal var fragmentFilter: ((fragmentClassName: String) -> Boolean)? = null

    /**
     * Starts observing activities now, before [Tugboat.start], so an activity
     * created earlier is known when a session starts later (a React Native
     * app starts the SDK from JavaScript, after the first activity resumed).
     * Call from the main thread before any activity is created, for example
     * from a `ContentProvider`. Calling again, or [Tugboat.start] afterwards,
     * does nothing more. Never throws.
     */
    @JvmStatic
    fun install(application: Application) {
        Tugboat.guarded("install") { NavigationObservation.ensureInstalled(application) }
    }

    /**
     * A name for a view that has no resource-id entry name, used wherever
     * identity reads the view's id name: the path segment (so the view is
     * kept), and the alias when the view also has a unique Android view id
     * (every React Native view does). A React Native app supplies its
     * `testID`. A resource-id name wins. Null clears it. A provider that
     * throws or returns null changes nothing.
     */
    @JvmStatic
    fun setViewNameProvider(provider: ((View) -> String?)?) {
        viewNameProvider = provider
    }

    /**
     * Fragments for which [filter] (given the fragment's class name) returns
     * true are not tracked: no navigation fact and no route key from them,
     * and the fragments they host are not tracked either. Set it before the
     * fragments appear: one already shown still leaves normally.
     * `react-native-screens` hosts every screen in a fragment of its own.
     * A throwing filter counts as no filter. Null clears it.
     */
    @JvmStatic
    fun setFragmentFilter(filter: ((fragmentClassName: String) -> Boolean)?) {
        fragmentFilter = filter
    }

    /**
     * The app names its own screens with [Tugboat.setScreen] (React Native):
     * the resumed activity is not a route, and the first screen named in a
     * session is its initial route (`session_start`), as in Flutter. An app
     * that then never names a screen reports no routes. Off by default; an
     * app that does not call this is unchanged. Set it before the session
     * starts.
     */
    @JvmStatic
    fun setHostNamesScreens(enabled: Boolean) {
        hostNamesScreens = enabled
    }

    /**
     * Whether a call begun now would be recorded: a session is running and
     * takes evidence. Adapters check it before running the app's route
     * resolver, as `tugboat_dio` does. Never throws.
     */
    @JvmStatic
    val isAcceptingEvidence: Boolean
        get() = Tugboat.guarded("isAcceptingEvidence") { Tugboat.isAcceptingEvidence } ?: false

    /**
     * Tests only: until the returned handle is closed, evidence goes to
     * [sink] as the engine message type and its input JSON (what the engine
     * would receive) instead of to a session. The evidence clock is
     * `System.nanoTime`. Closing restores the previous evidence path. Not for
     * app code: it replaces the running session's evidence.
     */
    @JvmStatic
    fun tapEvidenceForTesting(sink: (type: String, inputJson: String) -> Unit): AutoCloseable {
        val clock = HostClock { HostTime(System.nanoTime() / 1000, System.currentTimeMillis() * 1000) }
        val tap = EvidenceRecorder(clock, EngineEvidenceEncoder, hostRunning = { true }) { type, input, _ -> sink(type, input) }
        val previous = Tugboat.swapEvidence(tap)
        return AutoCloseable {
            tap.close()
            Tugboat.swapEvidence(previous)
        }
    }
}
