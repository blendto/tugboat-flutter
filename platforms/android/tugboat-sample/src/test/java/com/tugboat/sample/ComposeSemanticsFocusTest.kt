package com.tugboat.sample

import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The semantics screen opens with nothing focused, so no keyboard covers
 * its list (device test: step 11's fling landed on the keyboard); a tap
 * on the field still focuses it.
 */
@RunWith(RobolectricTestRunner::class)
class ComposeSemanticsFocusTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComposeSemanticsActivity>()

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
