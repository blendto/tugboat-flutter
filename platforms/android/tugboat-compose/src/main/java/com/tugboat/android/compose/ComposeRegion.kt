package com.tugboat.android.compose

import android.view.View
import com.tugboat.android.compose.focus.ComposeFocus
import com.tugboat.android.compose.identity.NodeTargets
import com.tugboat.android.compose.inventory.ComposeInventory
import com.tugboat.android.compose.mask.ComposeMasks
import com.tugboat.android.compose.mask.InteropViews
import com.tugboat.android.compose.scroll.ComposeScrollables
import com.tugboat.android.compose.semantics.ComposeUiVersion
import com.tugboat.android.compose.semantics.SemanticsAccess
import com.tugboat.android.toolkit.MaskCoverageReason
import com.tugboat.android.toolkit.RegionFocus
import com.tugboat.android.toolkit.RegionHit
import com.tugboat.android.toolkit.RegionInventory
import com.tugboat.android.toolkit.RegionMasks
import com.tugboat.android.toolkit.RegionScrollable
import com.tugboat.android.toolkit.ToolkitRegion

/**
 * The Compose toolkit region (native SDK note 2.1, 5, 6.2): Compose hosts
 * are `AndroidComposeView`s, read through their semantics trees. It keeps no
 * listeners; the Views adapter drives it, so it is inert once the adapter
 * stops.
 *
 * - **Masks**: the whole host by default ([ComposeMasking.WholeHost]), and
 *   always when the Compose UI version is unverified; semantics masks only
 *   with [ComposeMasking.SemanticsBestEffort], and the whole frame when the
 *   semantics owner is then unavailable.
 * - **Taps**: when the semantics tree is unavailable, the host view is
 *   anchored (toolkit `compose`).
 */
internal class ComposeRegion(
    private val masking: ComposeMasking,
    private val semantics: SemanticsAccess = SemanticsAccess.Default,
    private val versionVerified: () -> Boolean = { ComposeUiVersion.verified },
) : ToolkitRegion {
    override val toolkit: String = "compose"

    override val hostToken: String = "Compose"

    override fun hosts(view: View): Boolean = SemanticsAccess.isHost(view)

    override fun targetAt(host: View, x: Float, y: Float): RegionHit {
        if (InteropViews.contains(host, x, y)) return RegionHit.Miss
        val root = semantics.mergedRoot(host) ?: return RegionHit.Unreadable
        return NodeTargets.at(root, x, y)
    }

    override fun scrollablesAt(host: View, x: Float, y: Float): List<RegionScrollable> =
        ComposeScrollables.at(semantics.mergedRoot(host), x, y)

    override fun masks(host: View): RegionMasks =
        when {
            !versionVerified() -> RegionMasks.WholeHost(MaskCoverageReason.ComposeVersionUnverified)
            masking == ComposeMasking.WholeHost -> RegionMasks.WholeHost(MaskCoverageReason.ComposeDefault)
            else -> ComposeMasks.of(host, semantics.unmergedRoot(host))
        }

    override fun focus(host: View): RegionFocus? = ComposeFocus.of(semantics.unmergedRoot(host))

    override fun inventory(host: View, limit: Int): RegionInventory =
        ComposeInventory.of(host, semantics.mergedRoot(host), limit)
}
