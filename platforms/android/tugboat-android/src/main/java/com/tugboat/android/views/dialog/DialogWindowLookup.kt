package com.tugboat.android.views.dialog

import android.app.Dialog
import android.view.View
import android.view.Window
import androidx.lifecycle.findViewTreeLifecycleOwner
import com.tugboat.android.views.OptionalAndroidx

/**
 * The `Window` behind a dialog window's root view, through public API only.
 * A plain `Dialog` creates its own window with no public way back from its
 * decor view; the decor's view-tree lifecycle owner is that way:
 *
 * - `ComponentDialog` sets the decor's owner to the dialog itself in every
 *   `setContentView` (AppCompat `AlertDialog`, Material bottom sheets,
 *   Compose `Dialog`, material3 `ModalBottomSheet`, a `DialogFragment`'s
 *   default dialog).
 * - `DialogFragment.onStart` sets it to the fragment, whose `dialog` it is.
 *
 * A framework `android.app.Dialog` shown without a fragment has no owner and
 * no window here (a documented gap; its frames still carry `overlayWindow`).
 * The window found must have [root] as its decor, so an owner set on some
 * other root never adopts a window that is not this one.
 */
internal object DialogWindowLookup {
    fun windowOf(root: View): Window? {
        if (!OptionalAndroidx.lifecycleViews) return null
        val owner = root.findViewTreeLifecycleOwner() ?: return null
        val window =
            when {
                owner is Dialog -> owner.window
                OptionalAndroidx.fragment -> FragmentDialogWatcher.windowOf(owner)
                else -> null
            }
        return window?.takeIf { it.peekDecorView() === root }
    }
}
