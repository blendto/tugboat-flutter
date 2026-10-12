package com.tugboat.android.views.facts

import com.tugboat.android.host.EngineMessage
import com.tugboat.android.views.AdapterGuard

/** Where per-frame batches go: `EngineHost::postBatch` in the SDK. */
internal fun interface FactSink {
    fun postBatch(messages: List<EngineMessage>)
}

/**
 * Collects facts on the main thread and posts them once per frame as one
 * engine `batch` (native SDK note section 4). Each fact keeps its own time.
 *
 * [onFrame] runs first on every frame (and may [add]), so producers
 * that settle on a frame boundary (fragment removals, scroll idleness) can
 * add their facts to the same batch. Main thread only.
 */
internal class FactBatcher(
    private val sink: FactSink,
    private val frames: FrameScheduler,
    private val onFrame: () -> Unit = {},
) {
    private val pending = ArrayList<ViewsFact>()
    private var frameRequested = false

    fun add(fact: ViewsFact) {
        pending += fact
        requestFrame()
    }

    /** Requests a frame even with nothing pending, for hooks waiting on time. */
    fun requestFrame() {
        if (frameRequested) return
        frameRequested = true
        frames.postFrame { AdapterGuard.run("frame flush") { flush() } }
    }

    /** Posts everything pending now. Called by the frame callback and on stop. */
    fun flush() {
        frameRequested = false
        AdapterGuard.run("frame hook") { onFrame() }
        if (pending.isEmpty()) return
        val batch = pending.map(ViewsFact::toMessage)
        pending.clear()
        sink.postBatch(batch)
    }
}
