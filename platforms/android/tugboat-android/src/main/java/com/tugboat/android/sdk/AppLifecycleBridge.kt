package com.tugboat.android.sdk

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.tugboat.android.views.AdapterGuard

/**
 * Process lifecycle to the engine's `app.lifecycle` states, as Flutter's
 * `AppLifecycleState` arrives on Android:
 *
 * | `ProcessLifecycleOwner` | `app.lifecycle.state` |
 * | --- | --- |
 * | `ON_RESUME` | `resumed` |
 * | `ON_PAUSE` | `inactive` |
 * | `ON_STOP` | `paused` (teardown, background flush) |
 *
 * `ProcessLifecycleOwner` debounces pause and stop by 700 ms, so a rotation
 * or an activity switch is not a background. Registering replays the
 * current state, so a start while the app is visible reports `resumed`.
 * Main thread only.
 */
internal class AppLifecycleBridge(
    private val post: (state: String) -> Unit,
    private val owner: () -> LifecycleOwner = ProcessLifecycleOwner::get,
) : LifecycleEventObserver {
    private var observing = false

    fun start() = AdapterGuard.run("lifecycle start") {
        if (observing) return@run
        observing = true
        owner().lifecycle.addObserver(this)
    }

    fun stop() = AdapterGuard.run("lifecycle stop") {
        if (!observing) return@run
        observing = false
        owner().lifecycle.removeObserver(this)
    }

    override fun onStateChanged(source: LifecycleOwner, event: Lifecycle.Event) =
        AdapterGuard.run("lifecycle event") {
            if (!observing) return@run
            stateFor(event)?.let(post)
        }

    companion object {
        fun stateFor(event: Lifecycle.Event): String? =
            when (event) {
                Lifecycle.Event.ON_RESUME -> "resumed"
                Lifecycle.Event.ON_PAUSE -> "inactive"
                Lifecycle.Event.ON_STOP -> "paused"
                else -> null
            }
    }
}
