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

    /** Task of the most recently resumed activity; seeds visit that root last. */
    var lastResumedTaskId: Int? = null

    /** Clears process stacks (unit tests only). */
    internal fun resetForTests() {
        activityStacks.clear()
        fragmentStacks.clear()
        controllerStacks.clear()
        lastResumedTaskId = null
    }

    fun noteResumed(taskId: Int) {
        lastResumedTaskId = taskId
    }

    fun activityStack(taskId: Int, navigatorId: String): NavigatorStack =
        activityStacks.getOrPut(taskId) {
            NavigatorStack(navigatorId, null, hostKind = NavigatorHostKind.ActivityTask)
        }

    fun fragmentStack(
        navigatorId: String,
        parentNavigatorId: String,
        hostRouteInstanceId: String,
    ): NavigatorStack =
        fragmentStacks.getOrPut(navigatorId) {
            NavigatorStack(
                navigatorId,
                parentNavigatorId,
                hostRouteInstanceId,
                NavigatorHostKind.Fragments,
            )
        }

    fun controllerStack(
        navigatorId: String,
        parentNavigatorId: String,
        hostRouteInstanceId: String,
    ): NavigatorStack =
        controllerStacks.getOrPut(navigatorId) {
            NavigatorStack(
                navigatorId,
                parentNavigatorId,
                hostRouteInstanceId,
                NavigatorHostKind.Nav,
            )
        }

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
     * Non-empty stacks for `session_start`: orphans first, then each activity
     * task (background tasks first, the foreground task last). Per task:
     * navigators hosted by covered routes, the task stack, then the visible
     * chain under the top route (`fragments` before `nav` at each level).
     * The last seed is the deepest visible navigator, or the root stack when
     * the top route hosts nothing.
     */
    fun sessionStartSnapshots(): List<SessionStartSnapshot> {
        val hostedStacks = (fragmentStacks.values + controllerStacks.values).filter { it.top != null }
        val hostedByRoute = hostedStacks.groupBy { it.hostRouteInstanceId }
        val liveRouteIds = HashSet<String>()
        fun collectRouteIds(stack: NavigatorStack) {
            stack.all().forEach { liveRouteIds.add(it.instanceId) }
        }
        activityStacks.values.forEach { collectRouteIds(it) }
        fragmentStacks.values.forEach { collectRouteIds(it) }
        controllerStacks.values.forEach { collectRouteIds(it) }

        val out = ArrayList<SessionStartSnapshot>()
        val visited = HashSet<String>()

        fun hostedOrder(a: NavigatorStack, b: NavigatorStack): Int {
            val rankA = if (a.hostKind == NavigatorHostKind.Fragments) 0 else 1
            val rankB = if (b.hostKind == NavigatorHostKind.Fragments) 0 else 1
            return rankA - rankB
        }

        fun emit(stack: NavigatorStack) {
            if (!visited.add(stack.navigatorId)) return
            out.add(SessionStartSnapshot(stack.navigatorId, stack.parentNavigatorId, stack.all()))
        }

        fun walkNavigatorStack(stack: NavigatorStack) {
            fun walkHostedFromRoute(hostRouteId: String?) {
                if (hostRouteId == null) return
                val children = hostedByRoute[hostRouteId]?.sortedWith(::hostedOrder) ?: return
                for (child in children) walkNavigatorStack(child)
            }
            val topId = stack.top?.instanceId
            for (entry in stack.all()) {
                if (entry.instanceId != topId) walkHostedFromRoute(entry.instanceId)
            }
            emit(stack)
            walkHostedFromRoute(topId)
        }

        hostedStacks
            .filter { it.hostRouteInstanceId != null && it.hostRouteInstanceId !in liveRouteIds }
            .sortedWith(
                compareBy<NavigatorStack> { it.navigatorId }
                    .thenBy { if (it.hostKind == NavigatorHostKind.Fragments) 0 else 1 },
            )
            .forEach { emit(it) }

        val foreground = lastResumedTaskId
        val roots = activityStacks.entries
            .filter { it.value.top != null }
            .sortedWith(
                compareBy<Map.Entry<Int, NavigatorStack>> { (taskId, _) ->
                    if (foreground != null && taskId == foreground) 1 else 0
                }.thenBy { it.key },
            )
            .map { it.value }

        roots.forEach(::walkNavigatorStack)
        return out
    }
}
