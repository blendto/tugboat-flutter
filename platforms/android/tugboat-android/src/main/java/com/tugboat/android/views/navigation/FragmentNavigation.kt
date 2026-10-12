package com.tugboat.android.views.navigation

import android.app.Activity
import androidx.fragment.app.DialogFragment
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.FragmentManager
import com.tugboat.android.views.AdapterGuard
import com.tugboat.android.views.OptionalAndroidx
import com.tugboat.android.views.identity.Confidence
import java.util.WeakHashMap

/**
 * Navigation facts for androidx fragments, through
 * `registerFragmentLifecycleCallbacks(recursive = true)` on each
 * `FragmentActivity`. Created only when [OptionalAndroidx.fragment] is true.
 *
 * Each `FragmentManager` is a navigator, `<host instance id>/fragments`,
 * whose parent is the host's navigator. Only fragments with a view count;
 * headless fragments are ignored.
 *
 * - First resume: `push` when the back stack grew (or nothing is covered),
 *   `replace` when the covered fragment is leaving without a back-stack
 *   entry (it is being removed or was destroyed this frame).
 * - Resume below the top: `pop` back to it when everything above is being
 *   removed, else `push` (brought to front, as `ViewPager2` pages are).
 * - Destroyed while removed: resolved at the end of the frame ([flush]):
 *   a `pop` to the fragment below when it was the top, else `remove`.
 * - Fragments recreated with their activity keep their instance ids.
 *
 * Known gap: `hide`/`show` transactions do not resume fragments and are not
 * reported. Main thread only.
 */
internal class FragmentNavigation(
    private val activities: ActivityNavigation,
    private val destinations: DestinationTracker,
    private val roots: RouteRoots,
    private val report: (NavigationChange) -> Unit,
    private val requestFrame: () -> Unit,
) {
    private val entries = WeakHashMap<Fragment, RouteEntry>()
    private val stacks = HashMap<String, NavigatorStack>()
    private val backStackSizes = HashMap<String, Int>()
    private val recreating = HashMap<String, RouteEntry>()
    private val destroyed = ArrayList<Pair<NavigatorStack, RouteEntry>>()

    fun register(activity: Activity) {
        if (activity !is FragmentActivity) return
        activity.supportFragmentManager.registerFragmentLifecycleCallbacks(Callbacks(), true)
    }

    /** Reports fragments destroyed this frame that nothing replaced. */
    fun flush() {
        val pending = destroyed.toList()
        destroyed.clear()
        pending.forEach { (stack, entry) -> stack.remove(entry)?.let(report) }
    }

    /** Drops every navigator of a finishing activity. */
    fun forget(activity: Activity) {
        val prefix = activities.entryOf(activity)?.instanceId ?: return
        stacks.keys.removeAll { it.startsWith(prefix) }
        backStackSizes.keys.removeAll { it.startsWith(prefix) }
    }

    private inner class Callbacks : FragmentManager.FragmentLifecycleCallbacks() {
        override fun onFragmentResumed(fm: FragmentManager, f: Fragment) =
            AdapterGuard.run("fragment resumed") { onResumed(fm, f) }

        override fun onFragmentDestroyed(fm: FragmentManager, f: Fragment) =
            AdapterGuard.run("fragment destroyed") { onDestroyed(f) }
    }

    private fun onResumed(fm: FragmentManager, fragment: Fragment) {
        val view = fragment.view ?: return
        val stack = stackFor(fragment) ?: return
        val known = entries[fragment] ?: recreating.remove(recreationKey(stack, fragment))
        val change = when {
            known == null -> showNew(fm, fragment, stack)
            known !in stack -> stack.push(known)
            stack.top === known -> null
            stack.above(known).all(::isLeaving) -> stack.popTo(known)
            else -> stack.push(known)
        }
        val entry = known ?: entries[fragment] ?: return
        entries[fragment] = entry
        roots[view] = entry
        backStackSizes[stack.navigatorId] = fm.backStackEntryCount
        change?.let(report)
    }

    private fun showNew(fm: FragmentManager, fragment: Fragment, stack: NavigatorStack): NavigationChange {
        val entry = newEntry(fragment)
        entries[fragment] = entry
        val top = stack.top ?: return stack.push(entry)
        val grew = fm.backStackEntryCount > (backStackSizes[stack.navigatorId] ?: 0)
        if (grew || !isLeaving(top)) return stack.push(entry)
        destroyed.removeAll { it.second === top }
        return stack.replace(entry)
    }

    private fun onDestroyed(fragment: Fragment) {
        val entry = entries.remove(fragment) ?: return
        fragment.view?.let(roots::remove)
        val activity = fragment.activity
        val stack = stackFor(fragment) ?: return
        when {
            activity == null || activity.isFinishing -> Unit
            activity.isChangingConfigurations -> recreating[recreationKey(stack, fragment)] = entry
            else -> {
                destroyed += stack to entry
                requestFrame()
            }
        }
    }

    private fun newEntry(fragment: Fragment): RouteEntry {
        val destination = fragment.activity?.let(destinations::current)
        val tag = fragment.tag?.takeIf { it.isNotEmpty() }
        val dialog = fragment is DialogFragment
        return RouteEntry(
            instanceId = RouteEntry.newInstanceId("fragment"),
            routeKey = destination ?: tag ?: fragment.javaClass.name,
            confidence = if (destination != null || tag != null) Confidence.High else Confidence.Low,
            type = if (dialog) "DialogFragment" else "Fragment",
            overlayKind = if (dialog) OverlayKind.Dialog else OverlayKind.Page,
        )
    }

    /** True when [entry]'s fragment is being removed, was destroyed this frame, or is gone. */
    private fun isLeaving(entry: RouteEntry): Boolean {
        if (destroyed.any { it.second === entry }) return true
        val owner = entries.entries.firstOrNull { it.value === entry }?.key ?: return true
        return owner.isRemoving
    }

    /** [fragment]'s navigator: its host's instance id plus `/fragments`. Null before the host is shown. */
    private fun stackFor(fragment: Fragment): NavigatorStack? {
        val parent = fragment.parentFragment
        val (hostId, parentNavigatorId) = if (parent != null) {
            val parentEntry = entries[parent] ?: return null
            val parentStack = stackFor(parent) ?: return null
            parentEntry.instanceId to parentStack.navigatorId
        } else {
            val activity = fragment.activity ?: return null
            val activityEntry = activities.entryOf(activity) ?: return null
            activityEntry.instanceId to activities.navigatorIdOf(activity)
        }
        val navigatorId = "$hostId/fragments"
        return stacks.getOrPut(navigatorId) { NavigatorStack(navigatorId, parentNavigatorId) }
    }

    private fun recreationKey(stack: NavigatorStack, fragment: Fragment) =
        "${stack.navigatorId}|${fragment.javaClass.name}|${fragment.tag}|${fragment.id}"
}
