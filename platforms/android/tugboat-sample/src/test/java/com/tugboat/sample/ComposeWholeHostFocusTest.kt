package com.tugboat.sample

import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** The whole-host screen opens with nothing focused, like the semantics screen. */
@RunWith(RobolectricTestRunner::class)
class ComposeWholeHostFocusTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComposeWholeHostActivity>()

    @Test
    fun noNodeIsFocusedOnEntry() {
        compose.waitForIdle()
        compose.onNode(isFocused()).assertDoesNotExist()
    }
}
