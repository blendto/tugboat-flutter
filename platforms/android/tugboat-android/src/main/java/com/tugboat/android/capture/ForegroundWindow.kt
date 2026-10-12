package com.tugboat.android.capture

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.view.View
import android.view.Window
import com.tugboat.android.views.AdapterGuard
import java.lang.ref.WeakReference

/**
 * The window captures copy: the most recently resumed activity's. It also
 * watches that window's decor view for size changes and reports each new
 * boundary through [onBoundary] (the `surface` fact).
 *
 * Dialog and popup windows are separate windows and are not in the copy
 * (known gap, native SDK note section 5). Main thread only.
 */
internal class ForegroundWindow(
    private val application: Application,
    private val onBoundary: (BoundaryRect) -> Unit,
) : Application.ActivityLifecycleCallbacks {
    private var activity: WeakReference<Activity>? = null
    private var decor: View? = null
    private var started = false

    private val layoutListener = View.OnLayoutChangeListener { view, _, _, _, _, _, _, _, _ ->
        AdapterGuard.run("surface layout") { report(view) }
    }

    /** The foreground activity's window, or null in the background or before the first resume. */
    val window: Window?
        get() = activity?.get()?.takeUnless { it.isFinishing || it.isDestroyed }?.window

    fun start() = AdapterGuard.run("foreground window start") {
        if (started) return@run
        started = true
        application.registerActivityLifecycleCallbacks(this)
    }

    fun stop() = AdapterGuard.run("foreground window stop") {
        if (!started) return@run
        started = false
        application.unregisterActivityLifecycleCallbacks(this)
        unhook()
        activity = null
    }

    override fun onActivityResumed(activity: Activity) = AdapterGuard.run("foreground resumed") {
        this.activity = WeakReference(activity)
        val view = activity.window?.peekDecorView() ?: return@run
        if (view !== decor) {
            unhook()
            decor = view
            view.addOnLayoutChangeListener(layoutListener)
        }
        report(view)
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

    private fun unhook() {
        decor?.removeOnLayoutChangeListener(layoutListener)
        decor = null
    }
}
