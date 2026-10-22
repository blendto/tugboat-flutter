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

    /** Non-empty stacks: activities, fragment navigators, then `/nav` controllers. */
    fun sessionStartSnapshots(): List<SessionStartSnapshot> = buildList {
        appendSnapshots(activityStacks.values, this)
        appendSnapshots(fragmentStacks.values, this)
        appendSnapshots(controllerStacks.values, this)
    }

    private fun appendSnapshots(stacks: Collection<NavigatorStack>, out: MutableList<SessionStartSnapshot>) {
        stacks
            .sortedBy { it.navigatorId }
            .filter { it.top != null }
            .forEach { stack ->
                out.add(SessionStartSnapshot(stack.navigatorId, stack.parentNavigatorId, stack.all()))
            }
    }
}

internal data class SessionStartSnapshot(
    val navigatorId: String,
    val parentNavigatorId: String?,
    val routes: List<RouteEntry>,
)
