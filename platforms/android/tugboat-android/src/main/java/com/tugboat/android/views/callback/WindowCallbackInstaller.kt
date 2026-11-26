package com.tugboat.android.views.callback

import android.view.Window

/**
 * Installs Tugboat's window-callback wrapper on activity and dialog windows
 * so that other SDKs that wrap the same callback keep working:
 *
 * - The wrapper replaces the current callback and forwards everything to it.
 * - [ensureInstalled] runs on create and again on every resume. It wraps
 *   only when no Tugboat wrapper is reachable in the current chain
 *   ([CallbackChain]), so an SDK that re-wraps on every resume does not grow
 *   the chain with Tugboat wrappers. A callback replaced without chaining is
 *   wrapped again. A reachable wrapper that is inert (left by an ended
 *   session) or observed by another session is pointed at [observer], so a
 *   restarted SDK records again on windows whose wrapper is buried.
 * - [uninstall] unwraps when Tugboat's wrapper is on top. Below another
 *   SDK's wrapper it cannot, so it stays, keeps forwarding, and loses its
 *   observer (inert) until the next [ensureInstalled].
 */
internal object WindowCallbackInstaller {
    fun ensureInstalled(window: Window, observer: WindowEventObserver) {
        val current = window.callback ?: return
        val ours = CallbackChain.findTugboat(current)
        if (ours == null) {
            window.callback = ObservingWindowCallback(current, observer)
        } else if (ours.observer !== observer) {
            ours.observer = observer
        }
    }

    /**
     * Detaches [observer] from [window]. A wrapper another observer has
     * since adopted is left alone, so a late detach of an ended session
     * never silences the session that replaced it.
     */
    fun uninstall(window: Window, observer: WindowEventObserver) {
        val current = window.callback ?: return
        val ours = CallbackChain.findTugboat(current) ?: return
        if (ours.observer !== observer && ours.observer != null) return
        ours.observer = null
        if (ours === current) window.callback = ours.delegate
    }
}
