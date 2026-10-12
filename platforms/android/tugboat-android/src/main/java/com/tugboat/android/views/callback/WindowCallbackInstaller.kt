package com.tugboat.android.views.callback

import android.view.Window

/**
 * Installs [ObservingWindowCallback] on activity windows so that other SDKs
 * that wrap the same callback (Sentry, Firebase, Datadog) keep working:
 *
 * - The wrapper replaces the current callback and forwards everything to it.
 * - [ensureInstalled] runs on create and again on every resume. When the
 *   current callback is a Tugboat wrapper, nothing happens: the installer
 *   never wraps its own wrapper. When another SDK replaced the callback
 *   (chaining to ours or not), a new wrapper goes on top; if the old one is
 *   still in the chain, only the outermost observes (see the wrapper).
 * - [uninstall] unwraps only when Tugboat's wrapper is on top; below a
 *   foreign wrapper it stays in place and keeps forwarding, while the
 *   observer the caller passed is expected to go inert.
 */
internal object WindowCallbackInstaller {
    fun ensureInstalled(window: Window, observer: WindowEventObserver) {
        val current = window.callback ?: return
        if (current is TugboatWindowCallback) return
        window.callback = ObservingWindowCallback(current, observer)
    }

    fun uninstall(window: Window) {
        val current = window.callback as? ObservingWindowCallback ?: return
        window.callback = current.delegate
    }
}
