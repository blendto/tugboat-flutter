package com.tugboat.android.views.callback

import android.annotation.TargetApi
import android.os.Build
import android.view.ActionMode
import android.view.KeyEvent
import android.view.KeyboardShortcutGroup
import android.view.Menu
import android.view.MenuItem
import android.view.MotionEvent
import android.view.SearchEvent
import android.view.View
import android.view.Window
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import com.tugboat.android.views.AdapterGuard

/** What the adapter observes on an activity window. Called before the app sees the event. */
internal interface WindowEventObserver {
    fun onTouch(event: MotionEvent)

    fun onKey(event: KeyEvent)
}

/** The marker on Tugboat's wrapper: the installer never wraps a callback that has it. */
internal interface TugboatWindowCallback : Window.Callback

/**
 * Wraps the window callback it replaces ([delegate]) and forwards every
 * `Window.Callback` method to it, exactly once, returning its result. It
 * only observes touch and key events, before forwarding them, and never
 * consumes or alters anything. Observer failures are swallowed. Every
 * parameter the platform does not declare `@NonNull` is nullable here, so
 * no Kotlin null check can throw into the app.
 *
 * Several Tugboat wrappers can end up in one chain (another SDK wrapped
 * ours and we wrapped again on resume); only the outermost one observes an
 * event, so facts are never duplicated.
 */
internal class ObservingWindowCallback(
    val delegate: Window.Callback,
    private val observer: WindowEventObserver,
) : TugboatWindowCallback {
    override fun dispatchTouchEvent(event: MotionEvent?): Boolean {
        if (event != null) observeOnce { observer.onTouch(event) }
        return withDepth { delegate.dispatchTouchEvent(event) }
    }

    override fun dispatchKeyEvent(event: KeyEvent?): Boolean {
        if (event != null) observeOnce { observer.onKey(event) }
        return withDepth { delegate.dispatchKeyEvent(event) }
    }

    override fun dispatchKeyShortcutEvent(event: KeyEvent?): Boolean = delegate.dispatchKeyShortcutEvent(event)

    override fun dispatchTrackballEvent(event: MotionEvent?): Boolean = delegate.dispatchTrackballEvent(event)

    override fun dispatchGenericMotionEvent(event: MotionEvent?): Boolean = delegate.dispatchGenericMotionEvent(event)

    override fun dispatchPopulateAccessibilityEvent(event: AccessibilityEvent?): Boolean =
        delegate.dispatchPopulateAccessibilityEvent(event)

    override fun onCreatePanelView(featureId: Int): View? = delegate.onCreatePanelView(featureId)

    override fun onCreatePanelMenu(featureId: Int, menu: Menu): Boolean = delegate.onCreatePanelMenu(featureId, menu)

    override fun onPreparePanel(featureId: Int, view: View?, menu: Menu): Boolean =
        delegate.onPreparePanel(featureId, view, menu)

    override fun onMenuOpened(featureId: Int, menu: Menu): Boolean = delegate.onMenuOpened(featureId, menu)

    override fun onMenuItemSelected(featureId: Int, item: MenuItem): Boolean =
        delegate.onMenuItemSelected(featureId, item)

    override fun onWindowAttributesChanged(attrs: WindowManager.LayoutParams?) =
        delegate.onWindowAttributesChanged(attrs)

    override fun onContentChanged() = delegate.onContentChanged()

    override fun onWindowFocusChanged(hasFocus: Boolean) = delegate.onWindowFocusChanged(hasFocus)

    override fun onAttachedToWindow() = delegate.onAttachedToWindow()

    override fun onDetachedFromWindow() = delegate.onDetachedFromWindow()

    override fun onPanelClosed(featureId: Int, menu: Menu) = delegate.onPanelClosed(featureId, menu)

    override fun onSearchRequested(): Boolean = delegate.onSearchRequested()

    @TargetApi(Build.VERSION_CODES.M)
    override fun onSearchRequested(searchEvent: SearchEvent?): Boolean = delegate.onSearchRequested(searchEvent)

    override fun onWindowStartingActionMode(callback: ActionMode.Callback?): ActionMode? =
        delegate.onWindowStartingActionMode(callback)

    @TargetApi(Build.VERSION_CODES.M)
    override fun onWindowStartingActionMode(callback: ActionMode.Callback?, type: Int): ActionMode? =
        delegate.onWindowStartingActionMode(callback, type)

    override fun onActionModeStarted(mode: ActionMode?) = delegate.onActionModeStarted(mode)

    override fun onActionModeFinished(mode: ActionMode?) = delegate.onActionModeFinished(mode)

    @TargetApi(Build.VERSION_CODES.N)
    override fun onProvideKeyboardShortcuts(data: MutableList<KeyboardShortcutGroup>?, menu: Menu?, deviceId: Int) =
        delegate.onProvideKeyboardShortcuts(data, menu, deviceId)

    @TargetApi(Build.VERSION_CODES.O)
    override fun onPointerCaptureChanged(hasCapture: Boolean) = delegate.onPointerCaptureChanged(hasCapture)

    private inline fun observeOnce(block: () -> Unit) {
        if (dispatchDepth.get()!![0] > 0) return
        AdapterGuard.run("window event observer", block)
    }

    private inline fun <T> withDepth(block: () -> T): T {
        val depth = dispatchDepth.get()!!
        depth[0]++
        try {
            return block()
        } finally {
            depth[0]--
        }
    }

    private companion object {
        /** Tugboat wrappers currently dispatching on this thread. */
        val dispatchDepth: ThreadLocal<IntArray> = object : ThreadLocal<IntArray>() {
            override fun initialValue() = IntArray(1)
        }
    }
}
