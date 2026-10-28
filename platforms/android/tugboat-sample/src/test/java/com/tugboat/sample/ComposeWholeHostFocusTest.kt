package com.tugboat.sample

import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** The whole-host screen opens with nothing focused, like the semantics screen; a tap still focuses its field. */
@RunWith(RobolectricTestRunner::class)
class ComposeWholeHostFocusTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComposeWholeHostActivity>()

    @Test
    fun noNodeIsFocusedOnEntry() {
        compose.waitForIdle()
        compose.onNode(isFocused()).assertDoesNotExist()
    }

    @Test
    fun tappingTheFieldStillFocusesIt() {
        compose.onNodeWithText(compose.activity.getString(R.string.note_hint)).performClick()
        compose.waitForIdle()
        compose.onNode(isFocused()).assertExists()
    }
}
