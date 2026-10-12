package com.tugboat.android.views.mask

import android.view.View
import android.view.ViewGroup
import com.tugboat.android.views.identity.ViewTags

/**
 * Finds motion that layout geometry does not describe. `PixelCopy` copies
 * what is on screen, but mask rectangles come from layout bounds: a legacy
 * `View.startAnimation` (activity and fragment transitions use these) or a
 * running `LayoutTransition` draws content away from its bounds, so its text
 * can sit outside its mask. `ViewPropertyAnimator` / property animations are
 * fine: they change translation, scale, and alpha, which mask bounds include.
 *
 * Only visible views count; hidden and SDK-owned subtrees are skipped, as
 * the mask walk skips them.
 */
internal object AnimationProbe {
    fun isAnimating(root: View): Boolean {
        if (root.visibility != View.VISIBLE || ViewTags.isSdkOwned(root)) return false
        if (hasRunningAnimation(root)) return true
        if (root !is ViewGroup) return false
        if (root.layoutTransition?.isRunning == true) return true
        for (i in 0 until root.childCount) {
            if (isAnimating(root.getChildAt(i))) return true
        }
        return false
    }

    private fun hasRunningAnimation(view: View): Boolean {
        val animation = view.animation ?: return false
        return animation.hasStarted() && !animation.hasEnded()
    }
}
