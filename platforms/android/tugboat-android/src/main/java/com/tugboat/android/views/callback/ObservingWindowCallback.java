package com.tugboat.android.views.callback;

import android.annotation.TargetApi;
import android.os.Build;
import android.util.Log;
import android.view.ActionMode;
import android.view.KeyEvent;
import android.view.KeyboardShortcutGroup;
import android.view.Menu;
import android.view.MenuItem;
import android.view.MotionEvent;
import android.view.SearchEvent;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityEvent;
import java.util.List;

/**
 * Wraps the window callback it replaces ({@link #getDelegate()}) and forwards
 * every {@code Window.Callback} method to it, exactly once, returning its
 * result. It only observes touch and key events, before forwarding them, and
 * never consumes or alters anything.
 *
 * <p>Java on purpose: the platform passes {@code null} to parameters its
 * stubs declare non-null (a {@code null} menu, for example), and Kotlin would
 * insert parameter null checks that throw into the app. Nothing here checks
 * or dereferences an argument except the observed events.
 *
 * <p>If two Tugboat wrappers ever end up in one chain, only the outermost
 * observes an event (a per-thread dispatch depth), so facts are never
 * duplicated. {@link WindowCallbackInstaller} normally prevents that.
 */
final class ObservingWindowCallback implements TugboatWindowCallback {
    private static final String TAG = "TugboatViews";
    private static final ThreadLocal<int[]> DISPATCH_DEPTH =
            new ThreadLocal<int[]>() {
                @Override
                protected int[] initialValue() {
                    return new int[1];
                }
            };
    private static volatile boolean loggedFailure;

    private final Window.Callback delegate;
    private final WindowEventObserver observer;

    ObservingWindowCallback(Window.Callback delegate, WindowEventObserver observer) {
        this.delegate = delegate;
        this.observer = observer;
    }

    @Override
    public Window.Callback getDelegate() {
        return delegate;
    }

    @Override
    public boolean dispatchTouchEvent(MotionEvent event) {
        if (event != null && isOutermost()) {
            try {
                observer.onTouch(event);
            } catch (Throwable failure) {
                logOnce(failure);
            }
        }
        int[] depth = DISPATCH_DEPTH.get();
        depth[0]++;
        try {
            return delegate.dispatchTouchEvent(event);
        } finally {
            depth[0]--;
        }
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        if (event != null && isOutermost()) {
            try {
                observer.onKey(event);
            } catch (Throwable failure) {
                logOnce(failure);
            }
        }
        int[] depth = DISPATCH_DEPTH.get();
        depth[0]++;
        try {
            return delegate.dispatchKeyEvent(event);
        } finally {
            depth[0]--;
        }
    }

    @Override
    public boolean dispatchKeyShortcutEvent(KeyEvent event) {
        return delegate.dispatchKeyShortcutEvent(event);
    }

    @Override
    public boolean dispatchTrackballEvent(MotionEvent event) {
        return delegate.dispatchTrackballEvent(event);
    }

    @Override
    public boolean dispatchGenericMotionEvent(MotionEvent event) {
        return delegate.dispatchGenericMotionEvent(event);
    }

    @Override
    public boolean dispatchPopulateAccessibilityEvent(AccessibilityEvent event) {
        return delegate.dispatchPopulateAccessibilityEvent(event);
    }

    @Override
    public View onCreatePanelView(int featureId) {
        return delegate.onCreatePanelView(featureId);
    }

    @Override
    public boolean onCreatePanelMenu(int featureId, Menu menu) {
        return delegate.onCreatePanelMenu(featureId, menu);
    }

    @Override
    public boolean onPreparePanel(int featureId, View view, Menu menu) {
        return delegate.onPreparePanel(featureId, view, menu);
    }

    @Override
    public boolean onMenuOpened(int featureId, Menu menu) {
        return delegate.onMenuOpened(featureId, menu);
    }

    @Override
    public boolean onMenuItemSelected(int featureId, MenuItem item) {
        return delegate.onMenuItemSelected(featureId, item);
    }

    @Override
    public void onWindowAttributesChanged(WindowManager.LayoutParams attrs) {
        delegate.onWindowAttributesChanged(attrs);
    }

    @Override
    public void onContentChanged() {
        delegate.onContentChanged();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        delegate.onWindowFocusChanged(hasFocus);
    }

    @Override
    public void onAttachedToWindow() {
        delegate.onAttachedToWindow();
    }

    @Override
    public void onDetachedFromWindow() {
        delegate.onDetachedFromWindow();
    }

    @Override
    public void onPanelClosed(int featureId, Menu menu) {
        delegate.onPanelClosed(featureId, menu);
    }

    @Override
    public boolean onSearchRequested() {
        return delegate.onSearchRequested();
    }

    @Override
    public boolean onSearchRequested(SearchEvent searchEvent) {
        return delegate.onSearchRequested(searchEvent);
    }

    @Override
    public ActionMode onWindowStartingActionMode(ActionMode.Callback callback) {
        return delegate.onWindowStartingActionMode(callback);
    }

    @Override
    public ActionMode onWindowStartingActionMode(ActionMode.Callback callback, int type) {
        return delegate.onWindowStartingActionMode(callback, type);
    }

    @Override
    public void onActionModeStarted(ActionMode mode) {
        delegate.onActionModeStarted(mode);
    }

    @Override
    public void onActionModeFinished(ActionMode mode) {
        delegate.onActionModeFinished(mode);
    }

    @Override
    public void onProvideKeyboardShortcuts(List<KeyboardShortcutGroup> data, Menu menu, int deviceId) {
        delegate.onProvideKeyboardShortcuts(data, menu, deviceId);
    }

    @Override
    @TargetApi(Build.VERSION_CODES.O)
    public void onPointerCaptureChanged(boolean hasCapture) {
        delegate.onPointerCaptureChanged(hasCapture);
    }

    private static boolean isOutermost() {
        return DISPATCH_DEPTH.get()[0] == 0;
    }

    private static void logOnce(Throwable failure) {
        if (loggedFailure) return;
        loggedFailure = true;
        try {
            Log.w(TAG, "Views adapter window observer failed; further failures are not logged", failure);
        } catch (Throwable ignored) {
            // Logging must not throw into the app either.
        }
    }
}
