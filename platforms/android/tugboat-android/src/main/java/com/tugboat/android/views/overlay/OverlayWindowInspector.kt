package com.tugboat.android.views.overlay

import android.os.Build
import android.view.View
import android.view.Window
import android.view.inspector.WindowInspector
import com.tugboat.android.views.AdapterGuard

/** API 29+ scan of [WindowInspector.getGlobalWindowViews] at capture time. */
internal object OverlayWindowInspector {
    fun reportsOverlay(window: Window): Boolean =
        AdapterGuard.run("overlay window inspector", false) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return@run false
            val decor = window.peekDecorView()
            val roots = WindowInspector.getGlobalWindowViews()
            OverlayWindowRoots.hasOverlayRoot(roots, decor)
        }
}
