package com.tugboat.android.compose

import android.app.Activity
import android.view.View
import com.tugboat.android.compose.focus.ComposeFocus
import com.tugboat.android.compose.identity.NodeTargets
import com.tugboat.android.compose.mask.ComposeMasks
import com.tugboat.android.compose.mask.InteropViews
import com.tugboat.android.compose.navigation.ComposeRoutes
import com.tugboat.android.compose.scroll.ComposeScrollables
import com.tugboat.android.compose.semantics.SemanticsAccess
import com.tugboat.android.toolkit.RegionFocus
import com.tugboat.android.toolkit.RegionHit
import com.tugboat.android.toolkit.RegionMasks
import com.tugboat.android.toolkit.RegionScrollable
import com.tugboat.android.toolkit.ToolkitRegion

/**
 * The Compose toolkit region (native SDK note 5, 6.2): Compose hosts are
 * `AndroidComposeView`s, read through their semantics trees. It keeps no
 * listeners; the Views adapter drives it, so it is inert once the adapter
 * stops. When the semantics tree is unavailable, taps anchor the host view
 * (toolkit `compose`) and the whole frame is masked.
 */
internal class ComposeRegion(private val semantics: SemanticsAccess = SemanticsAccess.Default) : ToolkitRegion {
    private val routes = ComposeRoutes()

    override val toolkit: String = "compose"

    override val hostToken: String = "Compose"

    override fun hosts(view: View): Boolean = SemanticsAccess.isHost(view)

    override fun targetAt(host: View, x: Float, y: Float): RegionHit {
        if (InteropViews.contains(host, x, y)) return RegionHit.Miss
        val root = semantics.mergedRoot(host) ?: return RegionHit.Unreadable
        return NodeTargets.at(root, x, y)
    }

    override fun scrollables(host: View): List<RegionScrollable> = ComposeScrollables.of(semantics.mergedRoot(host))

    override fun masks(host: View): RegionMasks = ComposeMasks.of(host, semantics.unmergedRoot(host))

    override fun focus(host: View): RegionFocus? = ComposeFocus.of(semantics.unmergedRoot(host))

    override fun routeKey(host: View): String? = routes.routeFor(host)

    override fun onDestinationChanged(activity: Activity, route: String?) = routes.onDestinationChanged(activity, route)

    companion object {
        /** The region [TugboatCompose.install] registers. */
        val Default = ComposeRegion()
    }
}
