package com.tugboat.android.adapter

import com.tugboat.android.Tugboat
import com.tugboat.android.evidence.EngineEvidenceEncoder
import com.tugboat.android.evidence.EvidenceRecorder
import com.tugboat.android.host.HostClock
import com.tugboat.android.host.HostTime

/** What an HTTP-client adapter needs from the SDK besides the public network-call API. */
@TugboatAdapterApi
object TugboatAdapters {
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
