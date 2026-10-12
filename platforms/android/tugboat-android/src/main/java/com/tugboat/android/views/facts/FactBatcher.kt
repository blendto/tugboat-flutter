package com.tugboat.android.views.facts

import android.view.Choreographer
import com.tugboat.android.host.EngineMessage
import com.tugboat.android.views.AdapterGuard

/** Where per-frame batches go: `EngineHost::postBatch` in the SDK. */
internal fun interface FactSink {
    fun postBatch(messages: List<EngineMessage>)
}

/** Runs a callback on the next UI frame; [ChoreographerFrames] in production. */
internal fun interface FrameScheduler {
    fun postFrame(callback: () -> Unit)
}

/** The main thread's `Choreographer`. Must be created on the main thread. */
internal class ChoreographerFrames : FrameScheduler {
    private val choreographer = Choreographer.getInstance()

    override fun postFrame(callback: () -> Unit) = choreographer.postFrameCallback { callback() }
}

/**
 * Collects facts on the main thread and posts them once per frame as one
 * engine `batch` (native SDK note section 4). Each fact keeps its own time.
 *
 * [beforeFlush] runs first on every frame, so producers that settle on a
 * frame boundary (navigation, scroll idleness) can add their facts to the
 * same batch. Main thread only.
 */
internal class FactBatcher(
    private val sink: FactSink,
    private val frames: FrameScheduler,
) {
    private val pending = ArrayList<ViewsFact>()
    private var frameRequested = false
    private val frameHooks = ArrayList<() -> Unit>()

    fun add(fact: ViewsFact) {
        pending += fact
        requestFrame()
    }

    /** [hook] runs before each flush; it may [add] facts. Keep it cheap. */
    fun onFrame(hook: () -> Unit) {
        frameHooks += hook
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
        frameHooks.forEach { hook -> AdapterGuard.run("frame hook") { hook() } }
        if (pending.isEmpty()) return
        val batch = pending.map(ViewsFact::toMessage)
        pending.clear()
        sink.postBatch(batch)
    }
}
