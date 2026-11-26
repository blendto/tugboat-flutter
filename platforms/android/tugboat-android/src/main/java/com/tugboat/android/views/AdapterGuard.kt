package com.tugboat.android.views

import android.util.Log
import java.util.Collections

/**
 * Every adapter callback runs inside [run]: the host app never sees a
 * throwable from Tugboat. Each call site logs its first failure only, so a
 * failure on every frame cannot flood logcat.
 */
internal object AdapterGuard {
    private const val TAG = "TugboatViews"
    private val logged: MutableSet<String> = Collections.synchronizedSet(HashSet())

    inline fun <T> run(site: String, fallback: T, block: () -> T): T =
        try {
            block()
        } catch (failure: Throwable) {
            report(site, failure)
            fallback
        }

    inline fun run(site: String, block: () -> Unit) = run(site, Unit, block)

    fun report(site: String, failure: Throwable) {
        if (!logged.add(site)) return
        try {
            Log.w(TAG, "Views adapter $site failed; further failures here are not logged", failure)
        } catch (_: Throwable) {
            // Logging itself must not throw into the app either.
        }
    }
}
