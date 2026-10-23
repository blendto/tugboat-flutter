package com.tugboat.android.views.navigation

/**
 * Process-scoped navigator stacks. Survives [com.tugboat.android.views.ViewsAdapter]
 * stop/start so session_start can snapshot visible routes after
 * `TugboatRuntime.stop()` without waiting for another `onResumed`.
 *
 * Observation updates these stacks whenever lifecycle runs (even while the
 * adapter is stopped); only [com.tugboat.android.views.ViewsAdapter.start]
 * emits `session_start` from [sessionStartSnapshots].
 */
internal object NavigationProcessState {
    private val activityStacks = HashMap<Int, NavigatorStack>()
    private val fragmentStacks = HashMap<String, NavigatorStack>()
    private val controllerStacks = HashMap<String, NavigatorStack>()

    /** Clears process stacks (unit tests only). */
    internal fun resetForTests() {
        activityStacks.clear()
        fragmentStacks.clear()
        controllerStacks.clear()
    }

    fun activityStack(taskId: Int, navigatorId: String): NavigatorStack =
        activityStacks.getOrPut(taskId) { NavigatorStack(navigatorId, null) }

    fun fragmentStack(navigatorId: String, parentNavigatorId: String): NavigatorStack =
        fragmentStacks.getOrPut(navigatorId) { NavigatorStack(navigatorId, parentNavigatorId) }

    fun controllerStack(navigatorId: String, parentNavigatorId: String): NavigatorStack =
        controllerStacks.getOrPut(navigatorId) { NavigatorStack(navigatorId, parentNavigatorId) }

    fun forgetFragmentNavigator(navigatorId: String) {
        fragmentStacks.remove(navigatorId)
    }

    fun forgetController(navigatorId: String) {
        controllerStacks.remove(navigatorId)
    }

    fun forgetActivityTask(taskId: Int) {
        activityStacks.remove(taskId)
    }

    fun stackFor(navigatorId: String): NavigatorStack? =
        activityStacks.values.firstOrNull { it.navigatorId == navigatorId }
            ?: fragmentStacks[navigatorId]
            ?: controllerStacks[navigatorId]

    /**
     * Non-empty stacks in the order the engine must apply their seeds: each
     * activity task, then, for each of its routes bottom to top, the
     * navigators that route hosts (`<route instanceId>/fragments` before
     * `<route instanceId>/nav`), depth first. Parents precede children
     * (stateful-engine.md 8.1) and the chain under every top route comes
     * last, so the engine's visible route ends on the visible screen; ids
     * are never compared as strings (`activity-11` vs `activity-8`).
     * Navigators whose host route is gone come first, where they cannot
     * become the visible route.
     */
    fun sessionStartSnapshots(): List<SessionStartSnapshot> {
        val hosted = (fragmentStacks.values + controllerStacks.values)
            .filter { it.top != null }
            .groupBy { it.navigatorId.substringBeforeLast('/') }
        val out = ArrayList<SessionStartSnapshot>()
        val visited = HashSet<String>()
        fun visit(stack: NavigatorStack) {
            if (!visited.add(stack.navigatorId)) return
            out.add(SessionStartSnapshot(stack.navigatorId, stack.parentNavigatorId, stack.all()))
            stack.all().forEach { entry -> hosted[entry.instanceId]?.sortedBy(::hostedOrder)?.forEach(::visit) }
        }
        val roots = activityStacks.entries.sortedBy { it.key }.map { it.value }.filter { it.top != null }
        val hostIds = roots.flatMap { root -> root.all().map { it.instanceId } }.toHashSet()
        val reachable = HashSet<String>()
        fun mark(hostId: String) {
            hosted[hostId]?.forEach { child ->
                if (reachable.add(child.navigatorId)) child.all().forEach { mark(it.instanceId) }
            }
        }
        hostIds.forEach(::mark)
        hosted.values.flatten().filter { it.navigatorId !in reachable }.sortedBy(::hostedOrder).forEach(::visit)
        roots.forEach(::visit)
        return out
    }

    /** `/fragments` before `/nav` under the same host route. */
    private fun hostedOrder(stack: NavigatorStack): Int = if (stack.navigatorId.endsWith("/nav")) 1 else 0
}
