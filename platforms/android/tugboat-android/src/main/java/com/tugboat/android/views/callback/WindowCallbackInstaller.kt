package com.tugboat.android.views.callback

import android.view.Window

/**
 * Installs Tugboat's window-callback wrapper on activity windows so that
 * other SDKs that wrap the same callback (Sentry, Firebase, Datadog) keep
 * working:
 *
 * - The wrapper replaces the current callback and forwards everything to it.
 * - [ensureInstalled] runs on create and again on every resume. It wraps
 *   only when no Tugboat wrapper is reachable in the current chain
 *   ([CallbackChain]), so an SDK that re-wraps on every resume does not grow
 *   the chain with Tugboat wrappers. A callback replaced without chaining is
 *   wrapped again.
 * - [uninstall] unwraps only when Tugboat's wrapper is on top; below a
 *   foreign wrapper it stays and keeps forwarding, and the observer the
 *   caller passed is expected to go inert.
 */
internal object WindowCallbackInstaller {
    fun ensureInstalled(window: Window, observer: WindowEventObserver) {
        val current = window.callback ?: return
        if (CallbackChain.containsTugboat(current)) return
        window.callback = ObservingWindowCallback(current, observer)
    }

    fun uninstall(window: Window) {
        val current = window.callback as? TugboatWindowCallback ?: return
        window.callback = current.delegate
    }
}
