package com.tugboat.android.views.identity

import android.os.Build
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.webkit.WebView
import android.widget.Checkable
import android.widget.ImageView
import android.widget.TextView
import android.widget.VideoView
import com.tugboat.android.views.region.Regions
import com.tugboat.android.views.scroll.Scrollables

/**
 * Which views take part in identity (design note 6, 6.1).
 *
 * - **Excluded** with their subtree: not `VISIBLE`, zero alpha, zero size,
 *   or SDK-owned.
 * - **Kept**: actionable views, views with a resource id, scrollables,
 *   maskable leaves, and toolkit region hosts. Every other view collapses: its kept descendants attach
 *   to its nearest kept ancestor.
 *
 * Accessibility actions are not inspected: reading them builds an
 * `AccessibilityNodeInfo` per view, and androidx installs delegates on
 * ordinary views, so a delegate is no signal of an action.
 */
internal object ViewRules {
    fun isExcluded(view: View): Boolean =
        view.visibility != View.VISIBLE || view.alpha == 0f || view.width <= 0 || view.height <= 0 ||
            ViewTags.isSdkOwned(view)

    fun isActionable(view: View): Boolean =
        view.isClickable || view.isLongClickable || isContextClickable(view) || view is Checkable || isEditable(view)

    fun isEditable(view: View): Boolean = view is TextView && view.onCheckIsTextEditor()

    /** Leaves the mask covers (section 2.1, Views row). */
    fun isMaskableLeaf(view: View): Boolean =
        view is TextView || view is ImageView || view is WebView || view is VideoView ||
            view is SurfaceView || view is TextureView

    /** Region hosts (a Compose host, for example) are kept, so their content paths stay unique. */
    fun isKept(view: View, names: ResourceNames): Boolean =
        isActionable(view) || Scrollables.isScrollable(view) || isMaskableLeaf(view) || names.entryName(view) != null ||
            Regions.hostOf(view) != null

    private fun isContextClickable(view: View): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && view.isContextClickable
}
