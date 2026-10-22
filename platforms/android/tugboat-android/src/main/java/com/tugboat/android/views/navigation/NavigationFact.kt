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
    SessionStart("session_start"),
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
    val route: RouteEntry?,
    val departing: RouteEntry?,
    val routes: List<RouteEntry> = emptyList(),
) {
    fun toFact(at: HostTime): ViewsFact {
        val input = JSONObject()
            .put("kind", kind.wire)
            .put("navigatorId", navigatorId)
        parentNavigatorId?.let { input.put("parentNavigatorId", it) }
        if (kind == NavigationKind.SessionStart) {
            val routesJson = org.json.JSONArray()
            routes.forEach { entry -> routesJson.put(routeWireJson(entry)) }
            input.put("routes", routesJson)
        } else {
            val visible = route ?: error("route required for $kind")
            input.put("route", routeWireJson(visible))
            departing?.let {
                input.put("departing", JSONObject().put("instanceId", it.instanceId).put("name", it.routeKey).put("type", it.type))
            }
        }
        return ViewsFact(FactTypes.NAVIGATION, input, at)
    }

    companion object {
        private const val TRANSITION_UNKNOWN_MS = 0

        private fun routeWireJson(entry: RouteEntry): JSONObject =
            JSONObject()
                .put("instanceId", entry.instanceId)
                .put("name", entry.routeKey)
                .put("type", entry.type)
                .put("overlayKind", entry.overlayKind.wire)
                .put("transitionMs", TRANSITION_UNKNOWN_MS)

        fun sessionStart(snapshot: SessionStartSnapshot): NavigationChange =
            NavigationChange(
                kind = NavigationKind.SessionStart,
                navigatorId = snapshot.navigatorId,
                parentNavigatorId = snapshot.parentNavigatorId,
                route = null,
                departing = null,
                routes = snapshot.routes,
            )
    }

    override fun toString(): String = "${kind.wire} $navigatorId $route <- $departing"
}
