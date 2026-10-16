package com.tugboat.android.views.navigation

import android.app.Activity
import com.tugboat.android.views.identity.Confidence
import java.lang.ref.WeakReference
import java.util.WeakHashMap

/**
 * Navigation facts for activities: one navigator per task
 * (`activities:<taskId>`), driven by the lifecycle callbacks the adapter
 * receives. Resumes go through [NavigatorStack.onShown]:
 *
 * - first resume: `push`, or `replace` when the covered activity is
 *   finishing (it started this one and finished itself);
 * - resume below the top: `pop` back to it when everything above is
 *   finishing, else `push` (brought to front).
 *
 * Destroying a finishing activity below the top is a `remove` (the engine
 * ignores invisible removals); the last route leaving sends nothing.
 *
 * An activity destroyed **without** finishing (a configuration change, or the
 * system reclaiming a back-stack activity) is not navigation: its entry is
 * parked and the next instance of the same class in the same task takes it
 * over, keeping the instance id and sending nothing. Main thread only.
 */
internal class ActivityNavigation(private val report: (NavigationChange) -> Unit) {
    private val entries = WeakHashMap<Activity, RouteEntry>()
    private val stacks = HashMap<Int, NavigatorStack>()
    private val parked = HashMap<String, ArrayDeque<RouteEntry>>()

    fun entryOf(activity: Activity): RouteEntry? = entries[activity]

    fun navigatorIdOf(activity: Activity): String = "activities:${activity.taskId}"

    fun onCreated(activity: Activity) {
        val waiting = parked[parkingKey(activity)] ?: return
        val entry = waiting.removeLastOrNull() ?: return
        if (waiting.isEmpty()) parked.remove(parkingKey(activity))
        bind(activity, entry)
    }

    fun onResumed(activity: Activity) {
        val stack = stacks.getOrPut(activity.taskId) { NavigatorStack(navigatorIdOf(activity), null) }
        stack.onShown(ensureEntry(activity))?.let(report)
    }

    /** [activity]'s route, created before its first resume when a nested navigator needs it first. */
    fun ensureEntry(activity: Activity): RouteEntry = entries[activity] ?: bind(activity, newEntry(activity))

    fun onDestroyed(activity: Activity) {
        val entry = entries.remove(activity) ?: return
        if (!activity.isFinishing) {
            entry.isLeaving = { false }
            parked.getOrPut(parkingKey(activity)) { ArrayDeque() }.addLast(entry)
            return
        }
        val stack = stacks[activity.taskId] ?: return
        stack.remove(entry)?.takeIf { it.kind == NavigationKind.Remove }?.let(report)
        if (stack.top == null) stacks.remove(activity.taskId)
    }

    private fun bind(activity: Activity, entry: RouteEntry): RouteEntry {
        entries[activity] = entry
        val owner = WeakReference(activity)
        entry.isLeaving = { owner.get()?.let { it.isFinishing || it.isDestroyed } ?: true }
        return entry
    }

    private fun newEntry(activity: Activity) =
        RouteEntry(
            instanceId = RouteEntry.newInstanceId("activity"),
            routeKey = activity.javaClass.name,
            confidence = Confidence.High,
            type = "Activity",
            overlayKind = if (activity.window?.isFloating == true) OverlayKind.Dialog else OverlayKind.Page,
        )

    private fun parkingKey(activity: Activity) = "${activity.taskId}|${activity.javaClass.name}"
}
