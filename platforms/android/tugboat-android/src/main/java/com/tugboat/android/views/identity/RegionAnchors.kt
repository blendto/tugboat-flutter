package com.tugboat.android.views.identity

import android.view.View
import com.tugboat.android.toolkit.RegionHit
import com.tugboat.android.views.region.RegionHost
import com.tugboat.android.views.region.Regions

/**
 * Anchors inside toolkit regions (a Compose host, for example). The region
 * reads its own structure; this class gives it the Views context:
 *
 * - **Route**: the region's route key for the host when it has one (the
 *   `trackNavigation` route), else the host view's Views route.
 * - **Path**: the host's Views canonical path (the host is a kept view with
 *   its region's token) followed by the region's segments, so the full path
 *   is unique within the route even with several hosts.
 * - **Alias**: the region's alias; for the host itself, its `tugboatTag`.
 * - **Confidence**: as for Views: `high` with an alias, `medium` in a list
 *   item (or for a host with an id), else `low`; floored by the route.
 * - **Toolkit**: always the region's, including the host-identity fallback
 *   used when the region cannot be read.
 */
internal class RegionAnchors(
    private val names: ResourceNames,
    private val routes: RouteResolver,
    private val paths: CanonicalPathBuilder,
) {
    /**
     * Tap evidence when ([x], [y]) in [window] falls inside a region host, or
     * null when it does not or the region defers to the Views rules.
     */
    fun tapEvidence(hit: View, window: View, x: Float, y: Float): TapEvidence? {
        val host = Regions.enclosing(hit, window) ?: return null
        val local = ViewGeometry.toDescendant(window, host.view, x, y)
            ?: return TapEvidence.failed(TapEvidence.RESOLUTION_ERROR)
        val target = when (val result = host.targetAt(local[0], local[1])) {
            is RegionHit.Target -> result
            RegionHit.Unreadable -> null
            RegionHit.Miss -> return null
        }
        val anchor = anchor(host, target, window) ?: return TapEvidence.failed(TapEvidence.RESOLUTION_ERROR)
        return TapEvidence.of(anchor)
    }

    /** The anchor of [target] in [host], or of the host itself when [target] is null. */
    fun anchor(host: RegionHost, target: RegionHit.Target?, window: View = host.view.rootView): TargetAnchor? {
        val viewsRoute = routes.routeFor(host.view) ?: return null
        val route = host.routeKey()?.let { RouteKey(it, Confidence.High, viewsRoute.root) } ?: viewsRoute
        val hostPath = paths.build(route.root, host.view) ?: return null
        val path = (hostPath.segments + target?.path.orEmpty()).joinToString(separator = "/")
        val tag = if (target != null) target.tag else ViewTags.alias(host.view)
        val inListItem = hostPath.inListItem || target?.inListItem == true
        val bounds = if (target != null) ViewGeometry.mapRect(window, host.view, target.bounds) else ViewGeometry.boundsIn(window, host.view)
        return TargetAnchor(
            widgetType = target?.widgetType ?: host.region.hostToken,
            role = target?.role,
            fingerprint = IdentityHash.fingerprint(mapOf("routeKey" to route.value, "path" to path)),
            confidence = Confidence.floor(route.confidence, pathConfidence(host.view, target, tag, inListItem)),
            tagFingerprint = tag?.let { IdentityHash.fingerprint(mapOf("routeKey" to route.value, "tag" to it)) },
            routeKey = route.value,
            tag = tag,
            canonicalPath = path,
            relativePosition = RelativePosition.of(window, bounds),
            enabled = target?.enabled,
            actions = target?.actions.orEmpty(),
            toolkit = host.region.toolkit,
        )
    }

    private fun pathConfidence(host: View, target: RegionHit.Target?, tag: String?, inListItem: Boolean): Confidence =
        when {
            tag != null -> Confidence.High
            inListItem || (target == null && names.entryName(host) != null) -> Confidence.Medium
            else -> Confidence.Low
        }
}
