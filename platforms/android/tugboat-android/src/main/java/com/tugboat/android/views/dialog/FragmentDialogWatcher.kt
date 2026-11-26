package com.tugboat.android.views.dialog

import android.app.Activity
import android.view.Window
import androidx.fragment.app.DialogFragment
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.FragmentManager
import com.tugboat.android.views.AdapterGuard
import com.tugboat.android.views.OptionalAndroidx

/**
 * `DialogFragment` dialogs of one `FragmentActivity`, on every API level
 * (below API 29 the only dialogs that get facts): fragment lifecycle
 * callbacks, recursive so nested child managers count. A dialog fragment's
 * start runs after `DialogFragment.onStart` showed its dialog, so its decor
 * is attached; its stop runs after the dialog was hidden. An
 * `onCreateDialog`-only fragment (no view) counts like any other.
 *
 * Created only when [OptionalAndroidx.fragment] is true; every name it uses
 * from androidx.fragment stays inside this class. Main thread only.
 */
internal class FragmentDialogWatcher private constructor(
    private val manager: FragmentManager,
    private val onShown: (Window) -> Unit,
    private val onHidden: (Window) -> Unit,
    private val onGone: () -> Unit,
) : FragmentManager.FragmentLifecycleCallbacks() {
    private var registered = false

    fun register() {
        if (registered) return
        manager.registerFragmentLifecycleCallbacks(this, true)
        registered = true
    }

    fun unregister() {
        if (!registered) return
        manager.unregisterFragmentLifecycleCallbacks(this)
        registered = false
    }

    /** The windows of dialog fragments showing now, nested ones included (adoption at session start). */
    fun showingWindows(): List<Window> = ArrayList<Window>().also { collect(manager.fragments, it) }

    private fun collect(fragments: List<Fragment>, out: MutableList<Window>) {
        for (fragment in fragments) {
            showingWindow(fragment)?.let(out::add)
            if (fragment.isAdded) collect(fragment.childFragmentManager.fragments, out)
        }
    }

    override fun onFragmentStarted(fm: FragmentManager, f: Fragment) =
        AdapterGuard.run("dialog fragment started") { showingWindow(f)?.let(onShown) }

    override fun onFragmentStopped(fm: FragmentManager, f: Fragment) =
        AdapterGuard.run("dialog fragment stopped") { dialogWindow(f)?.let(onHidden) }

    override fun onFragmentDestroyed(fm: FragmentManager, f: Fragment) =
        AdapterGuard.run("dialog fragment destroyed") {
            if (f !is DialogFragment) return@run
            // The dialog is usually gone by now (dismissed in onDestroyView): sweep instead.
            dialogWindow(f)?.let(onHidden) ?: onGone()
        }

    companion object {
        /** A watcher for [activity] when it is a `FragmentActivity`. */
        fun forActivity(
            activity: Activity,
            onShown: (Window) -> Unit,
            onHidden: (Window) -> Unit,
            onGone: () -> Unit,
        ): FragmentDialogWatcher? =
            (activity as? FragmentActivity)?.let { FragmentDialogWatcher(it.supportFragmentManager, onShown, onHidden, onGone) }

        /** The dialog window of a view-tree lifecycle owner that is a `DialogFragment`. */
        fun windowOf(owner: Any): Window? = (owner as? DialogFragment)?.let(::dialogWindow)

        private fun dialogWindow(fragment: Fragment): Window? = (fragment as? DialogFragment)?.dialog?.window

        private fun showingWindow(fragment: Fragment): Window? {
            val dialogFragment = fragment as? DialogFragment ?: return null
            if (!dialogFragment.showsDialog) return null
            val dialog = dialogFragment.dialog ?: return null
            return if (dialog.isShowing) dialog.window else null
        }
    }
}
