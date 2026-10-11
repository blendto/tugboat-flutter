package com.tugboat.android.host

import android.util.Log

/**
 * Routes each [Effect] to its executor. Runs on the engine thread; answers
 * (`timer.fired`, `transport.result`) go back through [post].
 */
internal class EffectDispatcher(
    private val timers: TimerExecutor,
    private val http: HttpSender,
    private val frames: FrameHandleTable,
    private val post: (message: String) -> Unit,
) {
    private val reportedUnknown = HashSet<String>()

    fun dispatch(effect: Effect) {
        when (effect) {
            is Effect.TimerSchedule -> timers.schedule(effect.timerId, effect.atMonoUs)
            is Effect.TimerCancel -> timers.cancel(effect.timerId)
            is Effect.HttpSend -> http.send(effect.request) { outcome ->
                post(HostMessages.transportResult(effect.request.requestIdJson, outcome))
            }
            is Effect.FrameRelease -> frames.release(effect.handle)
            is Effect.Unknown -> if (reportedUnknown.add(effect.type)) {
                Log.w(TAG, "ignoring unknown effect type ${effect.type}")
            }
        }
    }

    private companion object {
        const val TAG = "TugboatEngine"
    }
}
