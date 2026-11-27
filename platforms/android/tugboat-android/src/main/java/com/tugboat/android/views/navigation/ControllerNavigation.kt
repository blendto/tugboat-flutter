package com.tugboat.android.views.navigation

import com.tugboat.android.views.identity.Confidence

/**
 * One back-stack entry of a Jetpack `NavController`, as the SDK facade reads
 * it (`NavBackStackEntry.id`, its destination's route and id). This module
 * has no Navigation dependency.
 */
internal data class NavEntry(val id: String, val route: String?, val destinationId: Int)

/**
 * Navigation facts for `NavController` destinations: one navigator per
 * controller's activity (`<activity route instanceId>/nav`), nested under the
 * activity navigator. The activity's route instance id survives a
 * recreation, and so do back-stack entry ids, so a recreated controller that
 * shows the same entry reports nothing.
 *
 * Each destination change is the new current entry and the one below it
 * (`previousBackStackEntry`):
 * - current already on the stack: `pop` back to it;
 * - new, and the entry below is the stack's top: `push`;
 * - new otherwise (the top was popped in the same navigation): `replace`.
 *
 * Route names are the route pattern without arguments ([RoutePattern]), so
 * `row/{index}` is `row`; type `NavDestination`, overlay `page`. Main thread
 * only.
 */
internal class ControllerNavigation(private val report: (NavigationChange) -> Unit) {
    private val entries = HashMap<String, RouteEntry>()

    /** [routeKey] is [current]'s route key (route pattern without arguments, else its id's entry name). */
    fun onDestinationChanged(
        navigatorId: String,
        parentNavigatorId: String,
        hostRouteInstanceId: String,
        current: NavEntry,
        routeKey: String,
        previous: NavEntry?,
    ) {
        val stack = NavigationProcessState.controllerStack(navigatorId, parentNavigatorId, hostRouteInstanceId)
        val known = entries[key(navigatorId, current.id)]
        val change = when {
            known != null && known in stack -> stack.popTo(known)
            previous == null || stack.top == null || stack.top?.instanceId == previous.id ->
                stack.push(entryFor(navigatorId, current, routeKey))
            else -> stack.replace(entryFor(navigatorId, current, routeKey))
        }
        change?.let(report)
    }

    /** Forgets [navigatorId] (its activity finished). */
    fun forget(navigatorId: String) {
        NavigationProcessState.forgetController(navigatorId)
        entries.keys.removeAll { it.startsWith("$navigatorId|") }
    }

    /** Forgets every controller stack and entry. */
    fun forgetAll() {
        NavigationProcessState.forgetAllControllers()
        entries.clear()
    }

    private fun entryFor(navigatorId: String, entry: NavEntry, routeKey: String): RouteEntry =
        entries.getOrPut(key(navigatorId, entry.id)) {
            RouteEntry(
                instanceId = entry.id,
                routeKey = routeKey,
                confidence = Confidence.High,
                type = TYPE,
                overlayKind = OverlayKind.Page,
            )
        }

    private fun key(navigatorId: String, entryId: String) = "$navigatorId|$entryId"

    companion object {
        const val TYPE = "NavDestination"

        fun navigatorIdFor(activityRouteInstanceId: String) = "$activityRouteInstanceId/nav"
    }
}
