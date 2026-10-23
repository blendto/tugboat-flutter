package com.tugboat.android.views.overlay

import android.view.View
import android.view.WindowManager

/**
 * Classifies global window roots for overlay detection (API 29+). A root other
 * than the captured activity's decor counts when it is shown and its
 * [WindowManager.LayoutParams.type] is in the application window range.
 */
internal object OverlayWindowRoots {
    fun hasOverlayRoot(roots: List<View>, activityDecor: View?): Boolean {
        if (activityDecor == null) return false
        for (root in roots) {
            if (root === activityDecor) continue
            if (isOverlayRoot(root)) return true
        }
        return false
    }

    fun isOverlayRoot(root: View): Boolean {
        if (!root.isShown) return false
        val params = root.layoutParams as? WindowManager.LayoutParams ?: return false
        if (params.type == WindowManager.LayoutParams.TYPE_APPLICATION_STARTING) return false
        return isApplicationRangeType(params.type)
    }

    private fun isApplicationRangeType(type: Int): Boolean =
        type in WindowManager.LayoutParams.TYPE_APPLICATION..WindowManager.LayoutParams.LAST_APPLICATION_WINDOW ||
            type in WindowManager.LayoutParams.FIRST_SUB_WINDOW..WindowManager.LayoutParams.LAST_SUB_WINDOW
}
