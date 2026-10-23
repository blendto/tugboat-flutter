package com.tugboat.android.sdk

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Emits `TUGBOAT_LAUNCH` / `TUGBOAT_HEALTH` for Device Farm correlation when
 * launch extras request capture. Main thread only.
 */
internal class LaunchCorrelation(
    private val sessionWallUs: Long?,
    private val handler: Handler = Handler(Looper.getMainLooper()),
    private val emit: (String) -> Unit = { line -> Log.i(TAG, line) },
) {
    private var launchLogged = false
    private var healthTask: Runnable? = null
    private var processLifecycle = "resumed"
    private var options: LaunchOptions? = null

    fun onProcessLifecycle(state: String) {
        processLifecycle = state
    }

    fun onActivityResumed(activity: Activity) {
        if (launchLogged) return
        val parsed = LaunchOptions.fromActivity(activity) ?: return
        options = parsed
        launchLogged = true
        emit("TUGBOAT_LAUNCH ${parsed.toLaunchJson(sessionWallUs)}")
        val task = Runnable { logHealth() }
        healthTask = task
        handler.postDelayed(task, HEALTH_DELAY_MS)
    }

    fun stop() {
        healthTask?.let { handler.removeCallbacks(it) }
        healthTask = null
    }

    private fun logHealth() {
        healthTask = null
        val wallUs = sessionWallUs ?: return
        val lifecycle = healthLifecycle(processLifecycle)
        emit("TUGBOAT_HEALTH ${LaunchOptions.healthJson(lifecycle, wallUs)}")
    }

    companion object {
        const val TAG = "Tugboat"
        const val HEALTH_DELAY_MS = 10_000L

        /** Maps engine `app.lifecycle` to the health `lifecycle` field. */
        fun healthLifecycle(appLifecycleState: String): String =
            when (appLifecycleState) {
                "resumed" -> "active"
                else -> appLifecycleState
            }
    }
}
