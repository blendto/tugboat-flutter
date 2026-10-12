package com.tugboat.android.views.navigation

import com.tugboat.android.host.HostTime
import com.tugboat.android.views.facts.FactTypes
import com.tugboat.android.views.facts.ViewsFact
import org.json.JSONObject

/** Engine `navigation.kind` values. */
internal enum class NavigationKind(val wire: String) {
    Push("push"),
    Pop("pop"),
    Replace("replace"),
    Remove("remove"),
}

/**
 * One stack change, as the engine's navigation fact (stateful-engine.md
 * 8.1): `{kind, navigatorId, parentNavigatorId?, route: {instanceId, name?,
 * type, overlayKind, transitionMs}, departing?: {instanceId, name?, type}}`.
 *
 * As in Flutter's `NavigatorObserver` mapping, [route] is the route visible
 * after the change (for `pop` and `remove`, the one below) and [departing]
 * the one leaving or covered. Android exposes no transition duration
 * without reading window animation resources, so `transitionMs` is 0.
 */
internal class NavigationChange(
    val kind: NavigationKind,
    val navigatorId: String,
    val parentNavigatorId: String?,
    val route: RouteEntry,
    val departing: RouteEntry?,
) {
    fun toFact(at: HostTime): ViewsFact {
        val input = JSONObject()
            .put("kind", kind.wire)
            .put("navigatorId", navigatorId)
        parentNavigatorId?.let { input.put("parentNavigatorId", it) }
        input.put(
            "route",
            JSONObject()
                .put("instanceId", route.instanceId)
                .put("name", route.routeKey)
                .put("type", route.type)
                .put("overlayKind", route.overlayKind.wire)
                .put("transitionMs", TRANSITION_UNKNOWN_MS),
        )
        departing?.let {
            input.put("departing", JSONObject().put("instanceId", it.instanceId).put("name", it.routeKey).put("type", it.type))
        }
        return ViewsFact(FactTypes.NAVIGATION, input, at)
    }

    override fun toString(): String = "${kind.wire} $navigatorId $route <- $departing"

    private companion object {
        const val TRANSITION_UNKNOWN_MS = 0
    }
}
