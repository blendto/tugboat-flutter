package com.tugboat.android.views.overlay

import android.app.Activity
import android.os.Build
import android.os.IBinder
import android.view.View
import android.view.Window
import android.view.WindowManager
import android.view.inspector.WindowInspector
import com.tugboat.android.toolkit.MaskCoverageReason
import com.tugboat.android.views.AdapterGuard
import com.tugboat.android.views.mask.WindowMaskResult

/**
 * Whether another window of this activity covers it when its window is
 * captured, for one window session. The copy holds the activity window
 * only, so such a frame is not what the user saw (fail closed: it keeps its
 * masks and reports [MaskCoverageReason.OverlayWindow]). Two public-API
 * signals, either one counts:
 *
 * - **Focus.** The activity window lost focus while the activity was
 *   resumed: a dialog, a focusable popup, or a system panel took it. Only
 *   regained focus clears it, not a pause: a dialog left up across Home and
 *   back keeps focus throughout, and the activity window gets no callback.
 *   A loss while not resumed is ignored, and the flag is read only while
 *   resumed. Below API 29 this is the only signal. Gaps there: a dialog
 *   shown before the window first gains focus is not seen (no `false`
 *   arrives); in multi-window mode, focus taken by another app's window
 *   flags frames too.
 * - **API 29+:** [WindowInspector.getGlobalWindowViews], classified by
 *   [OverlayWindowRoots]. In multi-window mode only this signal is used.
 *
 * Main thread only. A failure means "no overlay": detection never breaks a
 * capture.
 */
internal class OverlayDetector(private val activity: Activity) {
    private var resumed = false
    private var focusLost = false

    fun onResumed() {
        resumed = true
    }

    fun onPaused() {
        resumed = false
    }

    fun onWindowFocusChanged(hasFocus: Boolean) {
        if (hasFocus) {
            focusLost = false
        } else if (resumed) {
            focusLost = true
        }
    }

    /** Whether an overlay is up as [window] is copied. */
    fun atCapture(window: Window): Boolean =
        AdapterGuard.run("overlay detection", false) {
            val inspected = inspectedOverlay(window)
            if (inspected != null && activity.isInMultiWindowMode) {
                inspected
            } else {
                (resumed && focusLost) || inspected == true
            }
        }

    /** The API 29+ scan, or null below API 29. */
    private fun inspectedOverlay(window: Window): Boolean? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return OverlayWindowRoots.hasOverlayRoot(WindowInspector.getGlobalWindowViews(), OverlayWindowRoots.ownerTokens(window))
    }
}

/**
 * Classifies window roots (API 29+ global window views) for overlay
 * detection. A root counts when it is shown, belongs to the captured
 * activity window (its [WindowManager.LayoutParams.token] is one of
 * [ownerTokens]), and its type is
 *
 * - an application window above the activity's own (a dialog: from
 *   `TYPE_APPLICATION` through `LAST_APPLICATION_WINDOW`, without the
 *   starting window), or
 * - a focusable sub-window (`Spinner`, `PopupMenu`). Non-focusable
 *   popups (text-selection handles, tooltips) do not count, as they never
 *   take focus on older APIs either.
 *
 * Roots of another activity (a dialog left up behind this one) carry that
 * activity's token and do not count.
 */
internal object OverlayWindowRoots {
    fun hasOverlayRoot(roots: List<View>, ownerTokens: List<IBinder>): Boolean = roots.any { isOverlayRoot(it, ownerTokens) }

    fun isOverlayRoot(root: View, ownerTokens: List<IBinder>): Boolean {
        if (!root.isShown) return false
        val params = root.layoutParams as? WindowManager.LayoutParams ?: return false
        val token = params.token ?: return false
        if (token !in ownerTokens) return false
        return isApplicationOverlay(params.type) || isFocusableSubWindow(params)
    }

    /**
     * The tokens this activity's windows are added with: its app token (for
     * dialogs) and its decor's window token (for sub-windows).
     */
    fun ownerTokens(window: Window): List<IBinder> = listOfNotNull(window.attributes.token, window.peekDecorView()?.windowToken)

    private fun isApplicationOverlay(type: Int): Boolean =
        type in WindowManager.LayoutParams.TYPE_APPLICATION..WindowManager.LayoutParams.LAST_APPLICATION_WINDOW &&
            type != WindowManager.LayoutParams.TYPE_APPLICATION_STARTING

    private fun isFocusableSubWindow(params: WindowManager.LayoutParams): Boolean =
        params.type in WindowManager.LayoutParams.FIRST_SUB_WINDOW..WindowManager.LayoutParams.LAST_SUB_WINDOW &&
            (params.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE) == 0
}

/**
 * These masks, taken while an overlay window was up: they gain
 * [MaskCoverageReason.OverlayWindow], and the structure signature gains an
 * overlay token, so neither the runtime's dHash skip nor the engine's
 * coalescing merges this frame with one taken without the overlay (in
 * either direction).
 */
internal fun WindowMaskResult.withOverlayWindow(): WindowMaskResult =
    copy(coverage = coverage + MaskCoverageReason.OverlayWindow, structureSignature = structureSignature + OVERLAY_STRUCTURE_TOKEN)

private const val OVERLAY_STRUCTURE_TOKEN = "|overlayWindow"
