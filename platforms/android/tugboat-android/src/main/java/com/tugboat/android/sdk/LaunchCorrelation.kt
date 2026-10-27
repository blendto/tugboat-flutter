package com.tugboat.android.sdk

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.tugboat.android.TugboatLifecycleState
import com.tugboat.android.views.AdapterGuard

/**
 * Emits `TUGBOAT_LAUNCH` / `TUGBOAT_HEALTH` for Device Farm correlation when
 * launch extras request capture. Main thread only. LAUNCH and HEALTH fire at
 * most once per process (first `start()` wins).
 */
internal class LaunchCorrelation(
    private val sessionWallUs: Long,
    /** Read when HEALTH fires. */
    private val lifecycle: () -> LifecycleSnapshot,
    private val handler: Handler = Handler(Looper.getMainLooper()),
    private val emit: (String) -> Unit = { line -> Log.i(TAG, line) },
) {
    private var healthTask: Runnable? = null

    fun onActivityResumed(activity: Activity) {
        if (LaunchCorrelationLatch.launchLogged) return
        val parsed = LaunchOptions.fromActivity(activity) ?: return
        LaunchCorrelationLatch.launchLogged = true
        LaunchCorrelationLatch.firstSessionWallUs = sessionWallUs
        emit("TUGBOAT_LAUNCH ${parsed.toLaunchJson(sessionWallUs)}")
        val task = Runnable {
            AdapterGuard.run("launch health") { logHealth() }
        }
        healthTask = task
        handler.postDelayed(task, HEALTH_DELAY_MS)
    }

    fun stop() {
        healthTask?.let { handler.removeCallbacks(it) }
        healthTask = null
    }

    private fun logHealth() {
        healthTask = null
        if (!LaunchCorrelationLatch.launchLogged) return
        val wallUs = LaunchCorrelationLatch.firstSessionWallUs
        emit("TUGBOAT_HEALTH ${LaunchOptions.healthJson(lifecycle(), wallUs)}")
    }

    companion object {
        const val TAG = "Tugboat"
        const val HEALTH_DELAY_MS = 10_000L

        internal fun resetForTests() {
            LaunchCorrelationLatch.launchLogged = false
            LaunchCorrelationLatch.firstSessionWallUs = 0L
        }
    }
}

/** What `TUGBOAT_HEALTH` reports: `Tugboat.lifecycleState` and `Tugboat.activationRequestId`. */
internal data class LifecycleSnapshot(val state: TugboatLifecycleState, val activationRequestId: String?) {
    companion object {
        val DORMANT = LifecycleSnapshot(TugboatLifecycleState.DORMANT, null)
    }
}

/** Process-wide latch: first capture session id used for both correlation lines. */
internal object LaunchCorrelationLatch {
    @Volatile var launchLogged: Boolean = false
    @Volatile var firstSessionWallUs: Long = 0L
}
