package com.tugboat.android.views.identity

import android.view.View
import android.view.ViewGroup
import org.json.JSONObject

/** `tap {anchor | failureReason}` evidence for a pointer-up (stateful-engine.md 9.1). */
internal class TapEvidence private constructor(val anchor: TargetAnchor?, val failureReason: String?) {
    fun toJson(): JSONObject =
        if (anchor != null) JSONObject().put("anchor", anchor.toJson()) else JSONObject().put("failureReason", failureReason)

    companion object {
        fun of(anchor: TargetAnchor) = TapEvidence(anchor, null)

        /** One of the engine's closed `TapFailureReason` names. */
        fun failed(reason: String) = TapEvidence(null, reason)

        const val NO_TARGET_AT_POINT = "no_target_at_point"
        const val NO_ACTIONABLE_CANDIDATE = "no_actionable_candidate"
        const val RESOLUTION_ERROR = "resolution_error"
    }
}

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
 */
internal class AnchorResolver(
    private val names: ResourceNames,
    private val routes: RouteResolver,
) {
    private val paths = CanonicalPathBuilder(names)

    /** Tap evidence for a touch at ([x], [y]) in [window]'s decor coordinates. */
    fun tapEvidence(window: View, x: Float, y: Float): TapEvidence {
        val hit = HitTester.hit(window, x, y) ?: return TapEvidence.failed(TapEvidence.NO_TARGET_AT_POINT)
        val target = nearest(hit, window) { ViewRules.isActionable(it) }
            ?: nearest(hit, window) { ViewRules.isKept(it, names) }
            ?: return TapEvidence.failed(TapEvidence.NO_ACTIONABLE_CANDIDATE)
        val anchor = anchorFor(target, window) ?: return TapEvidence.failed(TapEvidence.RESOLUTION_ERROR)
        return TapEvidence.of(anchor)
    }

    /** The anchor of [view], or null when it is not attached under [window]. */
    fun anchorFor(view: View, window: View = view.rootView): TargetAnchor? {
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
            relativePosition = relativePosition(window, view),
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

    private fun relativePosition(window: View, view: View): String? {
        val bounds = ViewGeometry.boundsIn(window, view) ?: return null
        if (window.height <= 0) return null
        val centerY = bounds.centerY() / window.height
        return when {
            centerY < TOP_LIMIT -> "top"
            centerY > BOTTOM_LIMIT -> "bottom"
            else -> "center"
        }
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

    private companion object {
        // Flutter's `_relativePosition` thresholds.
        const val TOP_LIMIT = 0.33f
        const val BOTTOM_LIMIT = 0.66f
    }
}
