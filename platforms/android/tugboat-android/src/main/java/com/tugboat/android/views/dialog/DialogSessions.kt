package com.tugboat.android.views.dialog

import android.app.Activity
import android.os.Build
import android.view.View
import android.view.Window
import android.view.inspector.WindowInspector
import androidx.annotation.RequiresApi
import com.tugboat.android.views.OptionalAndroidx
import com.tugboat.android.views.overlay.OverlayWindowRoots
import java.util.WeakHashMap

/**
 * The dialog windows of one activity session, one [DialogWindowSession]
 * each, keyed by decor view. Dialogs are found, never polled (no per-frame
 * or layout scans; the root list is a fresh copy per call), when:
 *
 * - the activity window loses focus while resumed ([scanRoots], API 29+:
 *   `WindowInspector` roots of this activity in the application window
 *   range whose window [DialogWindowLookup] finds);
 * - a `DialogFragment` starts, on every API level ([FragmentDialogWatcher]);
 * - a session starts with dialogs already up ([adopt]).
 *
 * A session ends when its window detaches, its dialog fragment stops, the
 * activity window regains focus and its decor is no longer attached
 * ([sweepDetached]), or the activity session detaches ([detachAll]).
 * Main thread only.
 */
internal class DialogSessions(
    private val activity: Activity,
    private val context: DialogSessionContext,
) {
    private val sessions = WeakHashMap<View, DialogWindowSession>()
    private val fragments: FragmentDialogWatcher? =
        if (OptionalAndroidx.fragment) {
            FragmentDialogWatcher.forActivity(activity, onShown = ::track, onHidden = ::untrack, onGone = ::sweepDetached)
        } else {
            null
        }

    /** Live dialog sessions; for tests. */
    val size: Int
        get() = sessions.size

    /** Starts watching dialog fragments; idempotent. */
    fun start() {
        fragments?.register()
    }

    /** API 29+: attaches to this activity's dialog windows not yet tracked. Below 29, nothing (no public root list). */
    fun scanRoots() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        ownedDialogRoots().forEach { root ->
            if (!sessions.containsKey(root)) DialogWindowLookup.windowOf(root)?.let(::track)
        }
    }

    /** A session that starts with dialogs already up attaches to them. */
    fun adopt() {
        scanRoots()
        fragments?.showingWindows()?.forEach(::track)
    }

    fun sweepDetached() {
        sessions.entries.filter { it.key?.isAttachedToWindow != true }.forEach { (decor, session) ->
            sessions.remove(decor)
            session.detach()
        }
    }

    fun onFrame() {
        sessions.values.toList().forEach(DialogWindowSession::onFrame)
    }

    fun detachAll() {
        fragments?.unregister()
        val all = sessions.values.toList()
        sessions.clear()
        all.forEach(DialogWindowSession::detach)
    }

    private fun track(window: Window) {
        val decor = window.peekDecorView() ?: return
        if (!decor.isAttachedToWindow || sessions.containsKey(decor)) return
        val session = DialogWindowSession(window, decor, context, ::onWindowDetached)
        sessions[decor] = session
        session.attach()
    }

    private fun untrack(window: Window) {
        val decor = window.peekDecorView() ?: return
        sessions.remove(decor)?.detach()
    }

    private fun onWindowDetached(session: DialogWindowSession) {
        session.decor?.let { if (sessions[it] === session) sessions.remove(it) }
        session.detach()
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun ownedDialogRoots(): List<View> {
        val window = activity.window ?: return emptyList()
        val tokens = OverlayWindowRoots.ownerTokens(window)
        if (tokens.isEmpty()) return emptyList()
        return WindowInspector.getGlobalWindowViews().filter { OverlayWindowRoots.isOwnedDialogRoot(it, tokens) }
    }
}
