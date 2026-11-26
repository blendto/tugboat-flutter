package com.tugboat.android.compose

import android.util.Log
import com.tugboat.android.toolkit.ToolkitRegions

/**
 * The install entry point the app calls once when it ships `tugboat-compose`
 * (for example from `Application.onCreate`, after `Tugboat.start`). It lets
 * the Views adapter read Compose content (identity, scroll, focus, and masks
 * per [composeMasking]) instead of masking each Compose host over its whole
 * bounds as fail-closed. Installing again replaces the previous choice. Safe
 * to call from any thread; never throws.
 */
object TugboatCompose {
    private var installed: ComposeRegion? = null

    @JvmStatic
    @JvmOverloads
    @Synchronized
    fun install(composeMasking: ComposeMasking = ComposeMasking.WholeHost) {
        try {
            val region = ComposeRegion(composeMasking)
            installed?.let(ToolkitRegions::unregister)
            ToolkitRegions.register(region)
            installed = region
        } catch (failure: Throwable) {
            try {
                Log.w("TugboatCompose", "Compose adapter install failed; Compose hosts stay fail-closed", failure)
            } catch (_: Throwable) {
                // Logging must not throw into the app either.
            }
        }
    }
}
