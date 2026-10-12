package com.tugboat.android.compose

import android.util.Log
import com.tugboat.android.toolkit.ToolkitRegions

/**
 * The install entry point the Tugboat SDK facade calls when the app ships
 * `tugboat-compose`: it lets the Views adapter read Compose content
 * (identity, masks, scroll, focus) instead of masking every Compose host
 * whole. Idempotent, safe to call from any thread, and never throws.
 */
object TugboatCompose {
    @JvmStatic
    fun install() {
        try {
            ToolkitRegions.register(ComposeRegion.Default)
        } catch (failure: Throwable) {
            try {
                Log.w("TugboatCompose", "Compose adapter install failed; Compose hosts stay fail-closed", failure)
            } catch (_: Throwable) {
                // Logging must not throw into the app either.
            }
        }
    }
}
