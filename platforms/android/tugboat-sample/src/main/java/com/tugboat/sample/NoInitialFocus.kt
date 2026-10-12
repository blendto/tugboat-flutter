package com.tugboat.sample

import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.focusProperties

/**
 * Compose moves focus into the first focusable node when its host view
 * takes window focus on entry (a directional `Down` / `Next` entry), which
 * focused the text field and raised the keyboard over the list. Cancelling
 * directional entries keeps the screen unfocused; a tap on a field still
 * focuses it (an `Enter` request). These touch-only sample screens give up
 * D-pad entry for that.
 */
@Composable
internal fun NoInitialFocus(content: @Composable () -> Unit) {
    val noDirectionalEntry = Modifier.focusProperties {
        onEnter = { if (requestedFocusDirection != FocusDirection.Enter) cancelFocusChange() }
    }
    Box(noDirectionalEntry.focusGroup()) { content() }
}
