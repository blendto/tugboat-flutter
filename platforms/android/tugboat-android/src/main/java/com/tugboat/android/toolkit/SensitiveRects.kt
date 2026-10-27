package com.tugboat.android.toolkit

import android.graphics.RectF

/**
 * The rect rule a mask walk applies per view or node under
 * `tugboatSensitive`, shared by the Views walk and the Compose masks.
 *
 * - A node adds its [bounds] when it is a mask source or [marked], unless
 *   they lie inside [cover]: the last sensitive rect already added above it.
 *   A mark therefore only adds coverage, and a child inside its marked parent
 *   adds no second rect.
 * - Its children inherit the mark, and its rect (if added) as their cover.
 *
 * Outside a marked subtree [cover] is always null, so unmarked walks add
 * exactly their mask sources. Pure; no geometry is read here.
 */
@TugboatToolkitApi
object SensitiveRects {
    /** What one node contributes; [childCover] is null outside a marked subtree. */
    class Step(val addsRect: Boolean, val childCover: RectF?)

    private val unmarkedSource = Step(addsRect = true, childCover = null)
    private val nothing = Step(addsRect = false, childCover = null)

    fun step(marked: Boolean, isSource: Boolean, bounds: RectF?, cover: RectF?): Step {
        if (!marked) return if (isSource && bounds != null) unmarkedSource else nothing
        if (bounds == null || cover?.contains(bounds) == true) return Step(addsRect = false, childCover = cover)
        return Step(addsRect = true, childCover = bounds)
    }
}
