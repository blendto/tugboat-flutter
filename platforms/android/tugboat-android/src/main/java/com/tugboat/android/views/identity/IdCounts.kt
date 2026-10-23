package com.tugboat.android.views.identity

import android.view.View
import android.view.ViewGroup
import java.util.IdentityHashMap

/**
 * How many views under a route root carry each resource id, for the
 * unique-id alias ([AnchorResolver]). Each root is walked once, on first use;
 * [onWalk] counts those walks. One instance per tree walk: the counts are not
 * updated when the tree changes. Main thread only.
 */
internal class IdCounts(private val onWalk: () -> Unit = {}) {
    private val byRoot = IdentityHashMap<View, Map<Int, Int>>()

    /** The views under [root], itself included, whose id is [id]. */
    fun count(root: View, id: Int): Int = byRoot.getOrPut(root) { countAll(root) }[id] ?: 0

    private fun countAll(root: View): Map<Int, Int> {
        onWalk()
        val counts = HashMap<Int, Int>()
        collect(root, counts)
        return counts
    }

    private fun collect(view: View, counts: MutableMap<Int, Int>) {
        if (view.id != View.NO_ID) counts[view.id] = (counts[view.id] ?: 0) + 1
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) collect(view.getChildAt(i), counts)
        }
    }

    companion object {
        /** The views under [view], itself included, whose id is [id]: one subtree walk. */
        fun countWithId(view: View, id: Int): Int {
            var count = if (view.id == id) 1 else 0
            if (view is ViewGroup) {
                for (i in 0 until view.childCount) count += countWithId(view.getChildAt(i), id)
            }
            return count
        }
    }
}
