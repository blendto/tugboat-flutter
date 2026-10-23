package com.tugboat.android.views.identity

import android.view.View
import com.tugboat.android.views.region.Regions

/**
 * Resolves target anchors against the live View tree (design note 6, 6.1).
 *
 * - **Fingerprint**: hash of `routeKey` + the canonical path.
 * - **Alias**: the `tugboatTag`, else the resource entry name when no other
 *   view under the route root has the same id. It gives `tagFingerprint`
 *   (`routeKey` + `tag`) and leaves the structural fingerprint unchanged.
 * - **Confidence**: the floor of the route's and the path's. The path is
 *   high with an alias, medium when the target has its own id or sits in a
 *   list item, and low otherwise.
 * - **Toolkit regions**: a touch inside a region host (Compose) is resolved
 *   by its region first ([RegionAnchors]); the Views rules apply only when
 *   the region defers.
 */
internal class AnchorResolver(
    private val names: ResourceNames,
    private val routes: RouteResolver,
) {
    private val paths = CanonicalPathBuilder(names)

    /** Anchors inside toolkit regions, sharing this resolver's routes and paths. */
    val regions = RegionAnchors(names, routes, paths)

    /** Tap evidence for a touch at ([x], [y]) in [window]'s decor coordinates. */
    fun tapEvidence(window: View, x: Float, y: Float): TapEvidence {
        val hit = HitTester.hit(window, x, y) ?: return TapEvidence.failed(TapEvidence.NO_TARGET_AT_POINT)
        regions.tapEvidence(hit, window, x, y)?.let { return it }
        val target = nearest(hit, window) { ViewRules.isActionable(it) }
            ?: nearest(hit, window) { ViewRules.isKept(it, names) }
            ?: return TapEvidence.failed(TapEvidence.NO_ACTIONABLE_CANDIDATE)
        val anchor = anchorFor(target, window) ?: return TapEvidence.failed(TapEvidence.RESOLUTION_ERROR)
        return TapEvidence.of(anchor)
    }

    /** Subtree walks that counted resource ids, for tests: one per anchor, or one per route root with [IdCounts]. */
    var idCountWalks = 0
        private set

    /** Resource id counts shared by many [anchorFor] calls (one inventory walk): each route root is counted once. */
    fun idCounts(): IdCounts = IdCounts { idCountWalks++ }

    /**
     * The anchor of [view], or null when it is not attached under [window]. A
     * region host anchors as its region. [ids] shares id counts across calls;
     * without it each call counts its route root's ids.
     */
    fun anchorFor(view: View, window: View = view.rootView, ids: IdCounts? = null): TargetAnchor? {
        Regions.hostOf(view)?.let { return regions.anchor(it, target = null, window) }
        val route = routes.routeFor(view) ?: return null
        val path = paths.build(route.root, view) ?: return null
        val tag = alias(route.root, view, ids)
        val fingerprint = IdentityHash.fingerprint(mapOf("routeKey" to route.value, "path" to path.value))
        val role = ViewRoles.role(view)
        return TargetAnchor(
            widgetType = PlatformToken.name(view),
            role = role,
            fingerprint = fingerprint,
            confidence = Confidence.floor(route.confidence, pathConfidence(view, path, tag)),
            tagFingerprint = tag?.let { IdentityHash.fingerprint(mapOf("routeKey" to route.value, "tag" to it)) },
            routeKey = route.value,
            tag = tag,
            canonicalPath = path.value,
            relativePosition = RelativePosition.of(window, ViewGeometry.boundsIn(window, view)),
            enabled = if (role != null) view.isEnabled else null,
            actions = ViewRoles.actions(view),
        )
    }

    private fun pathConfidence(view: View, path: CanonicalPath, tag: String?): Confidence =
        when {
            tag != null -> Confidence.High
            names.entryName(view) != null || path.inListItem -> Confidence.Medium
            else -> Confidence.Low
        }

    private fun alias(root: View, view: View, ids: IdCounts?): String? {
        ViewTags.alias(view)?.let { return it }
        val name = names.entryName(view) ?: return null
        val count = if (ids != null) ids.count(root, view.id) else countIdOnce(root, view.id)
        return name.takeIf { count == 1 }
    }

    private fun countIdOnce(root: View, id: Int): Int {
        idCountWalks++
        return IdCounts.countWithId(root, id)
    }

    private inline fun nearest(start: View, stop: View, predicate: (View) -> Boolean): View? {
        var current: View? = start
        while (current != null) {
            if (predicate(current)) return current
            if (current === stop) return null
            current = current.parent as? View
        }
        return null
    }
}
