package com.tugboat.android.views.identity

import android.view.View
import android.view.ViewGroup
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

    /** The anchor of [view], or null when it is not attached under [window]. A region host anchors as its region. */
    fun anchorFor(view: View, window: View = view.rootView): TargetAnchor? {
        Regions.hostOf(view)?.let { return regions.anchor(it, target = null, window) }
        val route = routes.routeFor(view) ?: return null
        val path = paths.build(route.root, view) ?: return null
        val tag = alias(route.root, view)
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

    private fun alias(root: View, view: View): String? {
        ViewTags.alias(view)?.let { return it }
        val name = names.entryName(view) ?: return null
        return name.takeIf { countWithId(root, view.id) == 1 }
    }

    private fun countWithId(view: View, id: Int): Int {
        var count = if (view.id == id) 1 else 0
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) count += countWithId(view.getChildAt(i), id)
        }
        return count
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
