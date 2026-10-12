package com.tugboat.android.views.identity

import android.view.View
import android.view.ViewGroup
import android.widget.AbsListView
import com.tugboat.android.views.OptionalAndroidx
import com.tugboat.android.views.region.Regions

/** A target's structural path within its route root. */
internal class CanonicalPath(val segments: List<String>, val inListItem: Boolean) {
    val value: String
        get() = segments.joinToString(separator = "/")
}

/**
 * Builds canonical paths (design note 6.1).
 *
 * - A segment is the platform token ([PlatformToken]; a toolkit region host
 *   takes its region's host token) plus `#<ordinal>`, or
 *   `#<entry name>` when the view has a resource id. A repeated named token
 *   gets a further `#<ordinal>` (`Button#save#1`).
 * - Only kept views ([ViewRules.isKept]) get segments; the rest collapse.
 * - Ordinals count same-token siblings after filtering: the kept views (and
 *   list items) whose nearest kept ancestor is the same, in child order.
 * - A list child (`RecyclerView` adapter position, `AbsListView` first
 *   visible position + child index) adds `[item:<index>]` and scopes the
 *   ordinals of everything inside it.
 *
 * The route root itself is not part of the path.
 */
internal class CanonicalPathBuilder(private val names: ResourceNames) {
    /** [target]'s path below [root], or null when [target] is not inside it. */
    fun build(root: View, target: View): CanonicalPath? {
        val chain = chainBelow(root, target) ?: return null
        val segments = ArrayList<String>()
        var scope = root
        var inListItem = false
        for (view in chain) {
            val item = itemIndex(view)
            if (item != null) {
                segments += "[item:$item]"
                inListItem = true
                scope = view
                if (ViewRules.isKept(view, names)) segments += segment(token(view), 0)
                continue
            }
            if (!ViewRules.isKept(view, names)) continue
            val token = token(view)
            segments += segment(token, ordinal(scope, view, token))
            scope = view
        }
        return CanonicalPath(segments, inListItem)
    }

    /** `Button` or `Button#checkout`; a region host takes its region's host token (`Compose`). */
    fun token(view: View): String {
        val name = names.entryName(view)
        val platform = Regions.hostOf(view)?.region?.hostToken ?: PlatformToken.name(view)
        return if (name == null) platform else "$platform#$name"
    }

    private fun segment(token: String, ordinal: Int): String =
        when {
            !token.contains('#') -> "$token#$ordinal"
            ordinal == 0 -> token
            else -> "$token#$ordinal"
        }

    /** Ancestors strictly below [root] down to [target], top first. */
    private fun chainBelow(root: View, target: View): List<View>? {
        val chain = ArrayList<View>()
        var current: View = target
        while (current !== root) {
            chain += current
            current = current.parent as? View ?: return null
        }
        return chain.asReversed()
    }

    private fun ordinal(scope: View, view: View, token: String): Int {
        var ordinal = 0
        for (sibling in filteredChildren(scope)) {
            if (sibling === view) return ordinal
            if (itemIndex(sibling) == null && token(sibling) == token) ordinal++
        }
        return ordinal
    }

    /** The kept views and list items whose nearest scope is [scope], in child order. */
    private fun filteredChildren(scope: View): List<View> {
        val out = ArrayList<View>()
        collect(scope, out)
        return out
    }

    private fun collect(parent: View, out: MutableList<View>) {
        if (parent !is ViewGroup) return
        for (i in 0 until parent.childCount) {
            val child = parent.getChildAt(i)
            when {
                ViewRules.isExcluded(child) -> Unit
                itemIndex(child) != null || ViewRules.isKept(child, names) -> out += child
                else -> collect(child, out)
            }
        }
    }

    companion object {
        /** [child]'s list item index when its parent is a list, else null. */
        fun itemIndex(child: View): Int? {
            val parent = child.parent as? View ?: return null
            if (parent is AbsListView) return parent.firstVisiblePosition + parent.indexOfChild(child)
            val recycler = OptionalAndroidx.recycler
            if (recycler.isRecyclerView(parent)) return recycler.itemIndex(parent, child) ?: (parent as ViewGroup).indexOfChild(child)
            return null
        }
    }
}
