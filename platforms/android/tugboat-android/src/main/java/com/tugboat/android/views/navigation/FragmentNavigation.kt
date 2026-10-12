package com.tugboat.android.views.navigation

import android.app.Activity
import android.view.View
import androidx.fragment.app.DialogFragment
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.FragmentManager
import com.tugboat.android.views.AdapterGuard
import com.tugboat.android.views.OptionalAndroidx
import com.tugboat.android.views.identity.Confidence
import java.lang.ref.WeakReference
import java.util.WeakHashMap

/**
 * Navigation facts for androidx fragments, through
 * `registerFragmentLifecycleCallbacks(recursive = true)` on each
 * `FragmentActivity`. Created only when [OptionalAndroidx.fragment] is true.
 *
 * Each `FragmentManager` is a navigator, `<host instance id>/fragments`,
 * whose parent is the host's navigator (the activity's task, or the parent
 * fragment's). Only fragments with a view count; headless ones are ignored.
 *
 * - Resume goes through [NavigatorStack.onShown]: a new fragment covering
 *   one that is being removed is a `replace` unless the back stack grew
 *   (then a `push`); a resume below the top whose covering fragments are
 *   all being removed is a `pop`.
 * - A fragment destroyed while removed is settled at the end of the frame
 *   ([flush]): a `pop` to the one below when it was the top, else `remove`;
 *   a `replace` in the same frame absorbs it.
 * - A fragment destroyed without being removed (its activity is going away
 *   or being recreated) is parked; the recreated fragment (same navigator,
 *   class, tag, and container) takes over its instance id.
 * - A child fragment resumes before its parent's callback runs, so the
 *   parent is shown first and the parent's navigator change comes first.
 * - Navigators hosted by a route are dropped with it ([forget], or when the
 *   hosting fragment is removed), including nested child navigators.
 *
 * It also knows each shown fragment's root view, for route keys
 * ([routeRootedAt]). Known gap: `hide`/`show` transactions do not resume
 * fragments and are not reported. Main thread only.
 */
internal class FragmentNavigation(
    private val activities: ActivityNavigation,
    private val destinations: DestinationTracker,
    private val report: (NavigationChange) -> Unit,
    private val requestFrame: () -> Unit,
) {
    private val entries = WeakHashMap<Fragment, RouteEntry>()
    private val roots = WeakHashMap<View, RouteEntry>()
    private val stacks = HashMap<String, NavigatorStack>()
    private val navigatorsByHost = HashMap<String, MutableSet<String>>()
    private val backStackSizes = HashMap<String, Int>()
    private val parked = HashMap<String, RouteEntry>()
    private val destroyed = ArrayList<Pair<NavigatorStack, RouteEntry>>()
    private val registrations = WeakHashMap<FragmentActivity, Callbacks>()

    /** Navigator ids currently tracked; for tests. */
    val navigatorIds: Set<String>
        get() = stacks.keys.toSet()

    fun register(activity: Activity) {
        if (activity !is FragmentActivity || registrations.containsKey(activity)) return
        val callbacks = Callbacks()
        registrations[activity] = callbacks
        activity.supportFragmentManager.registerFragmentLifecycleCallbacks(callbacks, true)
    }

    fun unregister(activity: Activity) {
        val callbacks = registrations.remove(activity) ?: return
        (activity as FragmentActivity).supportFragmentManager.unregisterFragmentLifecycleCallbacks(callbacks)
    }

    fun unregisterAll() = registrations.keys.toList().forEach(::unregister)

    /** The shown fragment route whose root view is [view], if any. */
    fun routeRootedAt(view: View): RouteEntry? = roots[view]

    /** Reports fragments destroyed this frame that nothing replaced. */
    fun flush() {
        val pending = destroyed.toList()
        destroyed.clear()
        pending.forEach { (stack, entry) -> stack.remove(entry)?.let(report) }
    }

    /** Drops every navigator a finishing activity hosts, nested ones included. */
    fun forget(activity: Activity) {
        activities.entryOf(activity)?.let { dropNavigatorsHostedBy(it.instanceId) }
    }

    private inner class Callbacks : FragmentManager.FragmentLifecycleCallbacks() {
        override fun onFragmentResumed(fm: FragmentManager, f: Fragment) =
            AdapterGuard.run("fragment resumed") { onResumed(fm, f) }

        override fun onFragmentDestroyed(fm: FragmentManager, f: Fragment) =
            AdapterGuard.run("fragment destroyed") { onDestroyed(f) }
    }

    private fun onResumed(fm: FragmentManager, fragment: Fragment) {
        val view = fragment.view ?: return
        // Children resume before their parent's callback: show the parent first.
        fragment.parentFragment?.let { parent -> onResumed(parent.parentFragmentManager, parent) }
        val stack = stackFor(fragment) ?: return
        val entry = entries[fragment] ?: bind(fragment, parked.remove(parkingKey(stack, fragment)) ?: newEntry(fragment))
        val grew = fm.backStackEntryCount > (backStackSizes[stack.navigatorId] ?: 0)
        val change = stack.onShown(entry, keepLeavingTop = grew)
        if (change?.kind == NavigationKind.Replace) destroyed.removeAll { it.second === change.departing }
        roots[view] = entry
        backStackSizes[stack.navigatorId] = fm.backStackEntryCount
        change?.let(report)
    }

    private fun onDestroyed(fragment: Fragment) {
        val entry = entries.remove(fragment) ?: return
        fragment.view?.let(roots::remove)
        val stack = stackFor(fragment) ?: return
        if (!fragment.isRemoving) {
            entry.isLeaving = { false }
            parked[parkingKey(stack, fragment)] = entry
            return
        }
        // A removed fragment is reset after its destroy (`isRemoving` reads false again).
        entry.isLeaving = { true }
        dropNavigatorsHostedBy(entry.instanceId)
        destroyed += stack to entry
        requestFrame()
    }

    private fun bind(fragment: Fragment, entry: RouteEntry): RouteEntry {
        entries[fragment] = entry
        val owner = WeakReference(fragment)
        entry.isLeaving = { owner.get()?.isRemoving ?: true }
        return entry
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

    /** [fragment]'s navigator: its host's instance id plus `/fragments`. Null before the host is shown. */
    private fun stackFor(fragment: Fragment): NavigatorStack? {
        val parent = fragment.parentFragment
        val hostId: String
        val parentNavigatorId: String
        if (parent != null) {
            hostId = entries[parent]?.instanceId ?: return null
            parentNavigatorId = stackFor(parent)?.navigatorId ?: return null
        } else {
            val activity = fragment.activity ?: return null
            hostId = activities.entryOf(activity)?.instanceId ?: return null
            parentNavigatorId = activities.navigatorIdOf(activity)
        }
        val navigatorId = "$hostId/fragments"
        navigatorsByHost.getOrPut(hostId) { HashSet() } += navigatorId
        return stacks.getOrPut(navigatorId) { NavigatorStack(navigatorId, parentNavigatorId) }
    }

    private fun dropNavigatorsHostedBy(hostId: String) {
        val navigators = navigatorsByHost.remove(hostId) ?: return
        for (navigatorId in navigators) {
            val stack = stacks.remove(navigatorId) ?: continue
            backStackSizes.remove(navigatorId)
            parked.keys.removeAll { it.startsWith("$navigatorId|") }
            stack.all().forEach { dropNavigatorsHostedBy(it.instanceId) }
        }
    }

    private fun parkingKey(stack: NavigatorStack, fragment: Fragment) =
        "${stack.navigatorId}|${fragment.javaClass.name}|${fragment.tag}|${fragment.id}"
}
