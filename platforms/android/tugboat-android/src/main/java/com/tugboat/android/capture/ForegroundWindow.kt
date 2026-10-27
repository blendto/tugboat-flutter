package com.tugboat.android.capture

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.Window
import com.tugboat.android.views.AdapterGuard
import java.lang.ref.WeakReference

/**
 * The window captures copy: the most recently resumed activity's. It also
 * watches that window's decor view for size changes and reports each new
 * boundary through [onBoundary] (the `surface` fact).
 *
 * [start] adopts the activity [resumedActivity] reports (one already resumed
 * when a session starts) as if it had just resumed.
 *
 * Dialog and popup windows are separate windows and are not in the copy
 * (known gap, native SDK note section 5). Main thread only.
 */
internal class ForegroundWindow(
    private val application: Application,
    /** The activity resumed now, if known (process-scoped observation); read once by [start]. */
    private val resumedActivity: () -> Activity? = { null },
    private val onResumed: (Activity) -> Unit = {},
    private val onBoundary: (BoundaryRect) -> Unit,
) : Application.ActivityLifecycleCallbacks {
    private var activity: WeakReference<Activity>? = null
    private var decor: View? = null
    private var started = false
    private val handler by lazy { Handler(Looper.getMainLooper()) }
    private val waiting = ArrayList<Runnable>()

    private val layoutListener = View.OnLayoutChangeListener { view, _, _, _, _, _, _, _, _ ->
        AdapterGuard.run("surface layout") { report(view) }
    }

    /** The foreground activity's window, or null in the background or before the first resume. */
    val window: Window?
        get() = activity?.get()?.takeUnless { it.isFinishing || it.isDestroyed }?.window

    /**
     * Runs [onDone] once: as soon as an activity window is in the foreground
     * (at once if one is), or after [timeoutMs] without one.
     */
    fun awaitWindow(timeoutMs: Long, onDone: () -> Unit) {
        if (window != null) return onDone()
        val done = object : Runnable {
            override fun run() {
                if (waiting.remove(this)) onDone()
            }
        }
        waiting += done
        handler.postDelayed(done, timeoutMs)
    }

    fun start() = AdapterGuard.run("foreground window start") {
        if (started) return@run
        started = true
        application.registerActivityLifecycleCallbacks(this)
        // The same path as a resume, launch correlation included.
        resumedActivity()?.let(::onActivityResumed)
    }

    fun stop() = AdapterGuard.run("foreground window stop") {
        if (!started) return@run
        started = false
        application.unregisterActivityLifecycleCallbacks(this)
        unhook()
        activity = null
        releaseWaiting()
    }

    override fun onActivityResumed(activity: Activity) {
        // Its own guard: reading launch extras can throw (an unloadable
        // Parcelable), and that must not cost foreground tracking.
        AdapterGuard.run("launch correlation") { onResumed(activity) }
        trackResumed(activity)
    }

    private fun trackResumed(activity: Activity) = AdapterGuard.run("foreground resumed") {
        this.activity = WeakReference(activity)
        val view = activity.window?.peekDecorView() ?: return@run
        if (view !== decor) {
            unhook()
            decor = view
            view.addOnLayoutChangeListener(layoutListener)
        }
        report(view)
        releaseWaiting()
    }

    override fun onActivityDestroyed(activity: Activity) = AdapterGuard.run("foreground destroyed") {
        if (this.activity?.get() === activity) {
            unhook()
            this.activity = null
        }
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit

    override fun onActivityStarted(activity: Activity) = Unit

    override fun onActivityPaused(activity: Activity) = Unit

    override fun onActivityStopped(activity: Activity) = Unit

    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit

    private fun report(view: View) {
        CaptureGeometry.of(view)?.let { onBoundary(it.boundaryRect) }
    }

    private fun releaseWaiting() {
        waiting.toList().forEach { done ->
            handler.removeCallbacks(done)
            done.run()
        }
    }

    private fun unhook() {
        decor?.removeOnLayoutChangeListener(layoutListener)
        decor = null
    }
}
