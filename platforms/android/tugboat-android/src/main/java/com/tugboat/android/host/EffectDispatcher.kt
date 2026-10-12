package com.tugboat.android.host

import android.util.Log

/**
 * Routes each [Effect] to its executor. Runs on the engine thread; answers
 * (`transport.result`) go back through [post], stamped with the time they
 * arrive.
 */
internal class EffectDispatcher(
    private val timers: TimerExecutor,
    private val http: HttpSender,
    private val frames: FrameHandleTable,
    private val post: (type: String, inputJson: String) -> Unit,
    private val captures: CaptureRequestSink? = null,
) {
    private val reportedUnknown = HashSet<String>()

    fun dispatch(effect: Effect) {
        when (effect) {
            is Effect.TimerSchedule -> timers.schedule(effect.timerId, effect.atMonoUs)
            is Effect.TimerCancel -> timers.cancel(effect.timerId)
            is Effect.HttpSend -> http.send(effect.request) { outcome ->
                post(HostMessages.TRANSPORT_RESULT, HostMessages.transportResultInput(effect.request.requestId, outcome))
            }
            is Effect.FrameRelease -> frames.release(effect.handle)
            is Effect.CaptureRequest -> dispatchCapture(effect.request)
            is Effect.Unknown -> if (reportedUnknown.add(effect.type)) {
                Log.w(TAG, "ignoring unknown effect type ${effect.type}")
            }
        }
    }

    /** Without a capture sink the engine resolves the request at its answer deadline (C18). */
    private fun dispatchCapture(request: CaptureRequestEffect) {
        val sink = captures
        if (sink != null) {
            sink.onCaptureRequest(request)
        } else if (reportedUnknown.add("capture.request")) {
            Log.w(TAG, "no capture sink; capture requests go unanswered")
        }
    }

    private companion object {
        const val TAG = "TugboatEngine"
    }
}
