package com.tugboat.android.views.facts

import android.view.Choreographer

/** Runs a callback on the next UI frame; [ChoreographerFrames] in production. */
internal fun interface FrameScheduler {
    fun postFrame(callback: () -> Unit)
}

/** The main thread's `Choreographer`. Must be created on the main thread. */
internal class ChoreographerFrames : FrameScheduler {
    private val choreographer = Choreographer.getInstance()

    override fun postFrame(callback: () -> Unit) = choreographer.postFrameCallback { callback() }
}

/** Runs the callback immediately; unit tests only ([NavigationObservation.resetForTests]). */
internal object ImmediateFrames : FrameScheduler {
    override fun postFrame(callback: () -> Unit) = callback()
}
