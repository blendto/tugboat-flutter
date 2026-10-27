package com.tugboat.android.sdk

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.tugboat.android.TugboatLifecycleState
import com.tugboat.android.views.AdapterGuard

/**
 * Emits `TUGBOAT_LAUNCH` / `TUGBOAT_HEALTH` for Device Farm correlation when
 * launch extras request capture. Main thread only. Process-scoped (owned by
 * the `Tugboat` facade, fed by the resumed-activity tracker), so, like the
 * Flutter host that prints at config time, LAUNCH prints at the first
 * resume of an activity whose intent carries the extras whatever the
 * lifecycle state, and HEALTH [HEALTH_DELAY_MS] later. One of each per
 * process. Both read [captureSessionId] (the running session's, null when
 * none runs) and HEALTH reads [lifecycle] when the line prints, never from
 * the session running when the timer started. Only [cancelPendingHealth]
 * (`Tugboat.stop`) or [stop] cancels a pending HEALTH line.
 */
internal class LaunchCorrelation(
    /** `session-<wallUs>` of the running session, null when none runs. */
    private val captureSessionId: () -> String?,
    private val lifecycle: () -> LifecycleSnapshot,
    private val handler: Handler = Handler(Looper.getMainLooper()),
    private val emit: (String) -> Unit = { line -> Log.i(TAG, line) },
) {
    private var healthTask: Runnable? = null

    fun onActivityResumed(activity: Activity) {
        if (LaunchCorrelationLatch.launchLogged) return
        val parsed = LaunchOptions.fromActivity(activity) ?: return
        LaunchCorrelationLatch.launchLogged = true
        emit("TUGBOAT_LAUNCH ${parsed.toLaunchJson(captureSessionId())}")
        val task = Runnable { AdapterGuard.run("launch health") { logHealth(lifecycle(), captureSessionId()) } }
        healthTask = task
        LaunchCorrelationLatch.cancelHealth = { handler.removeCallbacks(task) }
        handler.postDelayed(task, HEALTH_DELAY_MS)
    }

    /** Cancels this instance's pending HEALTH line. */
    fun stop() {
        healthTask?.let { handler.removeCallbacks(it) }
        healthTask = null
        LaunchCorrelationLatch.cancelHealth = null
    }

    private fun logHealth(lifecycle: LifecycleSnapshot, captureSessionId: String?) {
        healthTask = null
        LaunchCorrelationLatch.cancelHealth = null
        emit("TUGBOAT_HEALTH ${LaunchOptions.healthJson(lifecycle, captureSessionId)}")
    }

    companion object {
        const val TAG = "Tugboat"
        const val HEALTH_DELAY_MS = 10_000L

        /** `Tugboat.stop`: cancels the pending HEALTH line, whichever instance scheduled it. Main thread. */
        fun cancelPendingHealth() {
            LaunchCorrelationLatch.cancelHealth?.invoke()
            LaunchCorrelationLatch.cancelHealth = null
        }

        internal fun resetForTests() {
            cancelPendingHealth()
            LaunchCorrelationLatch.launchLogged = false
        }

        /** The `captureSessionId` of a session whose `session.start` is at [wallUs]. */
        fun captureSessionId(wallUs: Long): String = "session-$wallUs"
    }
}

/** What `TUGBOAT_HEALTH` reports: `Tugboat.lifecycleState` and `Tugboat.activationRequestId`. */
internal data class LifecycleSnapshot(val state: TugboatLifecycleState, val activationRequestId: String?) {
    companion object {
        val DORMANT = LifecycleSnapshot(TugboatLifecycleState.DORMANT, null)
    }
}

/** Process-wide latch: LAUNCH (and so HEALTH) at most once per process. */
internal object LaunchCorrelationLatch {
    @Volatile var launchLogged: Boolean = false

    /** Cancels the pending HEALTH line; null when none is pending. Main thread. */
    var cancelHealth: (() -> Unit)? = null
}
