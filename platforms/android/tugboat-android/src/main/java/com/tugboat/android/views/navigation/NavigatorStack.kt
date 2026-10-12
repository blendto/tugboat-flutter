package com.tugboat.android.views.navigation

/**
 * The adapter's model of one navigator's stack (bottom first): an
 * activity task, or one `FragmentManager`. Each operation returns the
 * change to report, or null when nothing visible changed. The engine keeps
 * its own stacks; this one exists to tell push, pop, and replace apart.
 */
internal class NavigatorStack(val navigatorId: String, val parentNavigatorId: String?) {
    private val entries = ArrayList<RouteEntry>()

    val top: RouteEntry?
        get() = entries.lastOrNull()

    operator fun contains(entry: RouteEntry): Boolean = entries.any { it === entry }

    /** Every entry, bottom first. */
    fun all(): List<RouteEntry> = entries.toList()

    /**
     * [entry] became visible. Shown again on top: nothing. Below the top:
     * `pop` back to it when everything above is leaving, else `push` (brought
     * to front). New: `replace` when the covered top is leaving, unless
     * [keepLeavingTop] (it stays in a back stack), else `push`.
     */
    fun onShown(entry: RouteEntry, keepLeavingTop: Boolean = false): NavigationChange? {
        val top = top
        return when {
            top === entry -> null
            entry in this && above(entry).all { it.isLeaving() } -> popTo(entry)
            entry in this -> push(entry)
            top != null && top.isLeaving() && !keepLeavingTop -> replace(entry)
            else -> push(entry)
        }
    }

    /** The entries above [entry], or empty when it is the top or unknown. */
    fun above(entry: RouteEntry): List<RouteEntry> {
        val index = entries.indexOfFirst { it === entry }
        return if (index < 0) emptyList() else entries.subList(index + 1, entries.size).toList()
    }

    /** [entry] goes on top, covering the current top. */
    fun push(entry: RouteEntry): NavigationChange {
        val departing = top
        entries.remove(entry)
        append(entry)
        return change(NavigationKind.Push, entry, departing)
    }

    /** [entry] replaces the current top. */
    fun replace(entry: RouteEntry): NavigationChange {
        val departing = entries.removeLastOrNull()
        append(entry)
        return change(NavigationKind.Replace, entry, departing)
    }

    /** Everything above [entry] leaves; [entry] is visible again. */
    fun popTo(entry: RouteEntry): NavigationChange? {
        val index = entries.indexOfFirst { it === entry }
        if (index < 0 || index == entries.lastIndex) return null
        val departing = top
        while (entries.lastIndex > index) entries.removeAt(entries.lastIndex)
        return change(NavigationKind.Pop, entry, departing)
    }

    /**
     * [entry] leaves. Leaving from the top is a `pop` to the route below;
     * from below the top, an (invisible) `remove`. Null when nothing remains
     * to show or [entry] is unknown.
     */
    fun remove(entry: RouteEntry): NavigationChange? {
        val index = entries.indexOfFirst { it === entry }
        if (index < 0) return null
        val wasTop = index == entries.lastIndex
        entries.removeAt(index)
        val visible = top ?: return null
        return change(if (wasTop) NavigationKind.Pop else NavigationKind.Remove, visible, entry)
    }

    /** Appends [entry], dropping the bottom beyond [MAX_ENTRIES] (the engine keeps 16). */
    private fun append(entry: RouteEntry) {
        entries += entry
        while (entries.size > MAX_ENTRIES) entries.removeAt(0)
    }

    private fun change(kind: NavigationKind, route: RouteEntry, departing: RouteEntry?) =
        NavigationChange(kind, navigatorId, parentNavigatorId, route, departing)

    private companion object {
        const val MAX_ENTRIES = 64
    }
}
