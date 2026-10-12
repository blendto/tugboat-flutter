package com.tugboat.android.views.callback

import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Window

/** What the adapter observes on an activity window. Called before the app sees the event. */
internal interface WindowEventObserver {
    fun onTouch(event: MotionEvent)

    fun onKey(event: KeyEvent)
}

/**
 * The marker on Tugboat's wrapper (`ObservingWindowCallback.java`): the
 * installer never wraps a chain that already contains one.
 */
internal interface TugboatWindowCallback : Window.Callback {
    /** The callback this wrapper replaced and forwards to. */
    val delegate: Window.Callback
}
