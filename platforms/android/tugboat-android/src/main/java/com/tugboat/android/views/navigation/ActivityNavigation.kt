package com.tugboat.android.views.navigation

import android.app.Activity
import com.tugboat.android.views.identity.Confidence
import java.util.WeakHashMap

/**
 * Navigation facts for activities: one navigator per task
 * (`activities:<taskId>`), driven by the lifecycle callbacks the adapter
 * receives.
 *
 * - First resume of an instance: `push`, or `replace` when the activity it
 *   covers is finishing (it started this one and finished itself).
 * - Resume of an instance below the top: `pop` back to it when everything
 *   above is finishing, else `push` (brought to front).
 * - Destroy while finishing: `remove` when it was below the top (the engine
 *   ignores invisible removals); nothing when it was the last route.
 * - Configuration-change recreation keeps the instance id and sends nothing:
 *   the new instance (same class, same task) takes over the old entry.
 *
 * Main thread only.
 */
internal class ActivityNavigation(private val report: (NavigationChange) -> Unit) {
    private val entries = WeakHashMap<Activity, RouteEntry>()
    private val stacks = HashMap<Int, NavigatorStack>()
    private val recreating = HashMap<String, RouteEntry>()

    fun entryOf(activity: Activity): RouteEntry? = entries[activity]

    fun navigatorIdOf(activity: Activity): String = "activities:${activity.taskId}"

    fun onCreated(activity: Activity) {
        recreating.remove(recreationKey(activity))?.let { entries[activity] = it }
    }

    fun onResumed(activity: Activity) {
        val stack = stacks.getOrPut(activity.taskId) { NavigatorStack(navigatorIdOf(activity), null) }
        val known = entries[activity]
        val change = when {
            known == null -> showNew(activity, stack)
            known !in stack -> stack.push(known)
            stack.top === known -> null
            stack.above(known).all(::isFinishing) -> stack.popTo(known)
            else -> stack.push(known)
        }
        change?.let(report)
    }

    fun onDestroyed(activity: Activity) {
        val entry = entries.remove(activity) ?: return
        if (activity.isChangingConfigurations) {
            recreating[recreationKey(activity)] = entry
            return
        }
        val stack = stacks[activity.taskId] ?: return
        stack.remove(entry)?.takeIf { it.kind == NavigationKind.Remove }?.let(report)
        if (stack.top == null) stacks.remove(activity.taskId)
    }

    private fun showNew(activity: Activity, stack: NavigatorStack): NavigationChange {
        val entry = RouteEntry(
            instanceId = RouteEntry.newInstanceId("activity"),
            routeKey = activity.javaClass.name,
            confidence = Confidence.High,
            type = "Activity",
            overlayKind = if (activity.window?.isFloating == true) OverlayKind.Dialog else OverlayKind.Page,
        )
        entries[activity] = entry
        val top = stack.top
        return if (top != null && isFinishing(top)) stack.replace(entry) else stack.push(entry)
    }

    private fun isFinishing(entry: RouteEntry): Boolean {
        val owner = entries.entries.firstOrNull { it.value === entry }?.key ?: return true
        return owner.isFinishing || owner.isDestroyed
    }

    private fun recreationKey(activity: Activity) = "${activity.taskId}|${activity.javaClass.name}"
}
