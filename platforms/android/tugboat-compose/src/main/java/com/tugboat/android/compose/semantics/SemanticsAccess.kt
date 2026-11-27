package com.tugboat.android.compose.semantics

import android.view.View
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsOwner

/**
 * The only door into Compose internals (native SDK note 6.2): a Compose
 * host is a View implementing `ViewRootForTest` (`AndroidComposeView`), and
 * its `semanticsOwner` is treated as unstable API, reached through
 * `runCatching`. Null means "unavailable": callers fall back to the host's
 * View identity and mask the whole frame.
 */
internal fun interface SemanticsAccess {
    fun ownerOf(host: View): SemanticsOwner?

    /** The merged tree (identity, scroll), or null when unavailable. */
    fun mergedRoot(host: View): SemanticsNode? = runCatching { ownerOf(host)?.rootSemanticsNode }.getOrNull()

    /** The unmerged tree (masks, focus), or null when unavailable. */
    fun unmergedRoot(host: View): SemanticsNode? = runCatching { ownerOf(host)?.unmergedRootSemanticsNode }.getOrNull()

    companion object {
        /** True for a Compose host view. */
        fun isHost(view: View): Boolean = view is ViewRootForTest

        val Default = SemanticsAccess { host -> runCatching { (host as? ViewRootForTest)?.semanticsOwner }.getOrNull() }
    }
}
