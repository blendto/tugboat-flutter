package com.tugboat.android.compose

import androidx.activity.ComponentActivity
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import com.tugboat.android.compose.semantics.SemanticsAccess
import com.tugboat.android.views.mask.MaskRect
import com.tugboat.android.views.mask.WindowMasks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * When the semantics owner cannot be reached (native SDK note 6.2): taps
 * anchor the hosting View with `toolkit: "compose"`, and the whole frame is
 * masked. A throwing owner behaves the same.
 */
@RunWith(RobolectricTestRunner::class)
class OwnerUnavailableTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain =
        RuleChain.outerRule(RegionRule(ComposeRegion(SemanticsAccess { error("semantics owner moved") }))).around(compose)

    @Before
    fun setUp() {
        compose.setContent { Button(onClick = {}) { Text("Pay") } }
    }

    @Test
    fun theWholeFrameIsMasked() {
        val result = WindowMasks.compute(compose.activity.window)
        assertTrue(result.failClosed)
        assertEquals(listOf(MaskRect.FULL_FRAME), result.rects)
    }

    @Test
    fun tapsFallBackToTheHostViewIdentityAsCompose() {
        val anchor = anchorResolver(compose.activity).tapAt(compose.activity, compose.onNodeWithText("Pay")).anchor()
        assertEquals("compose", anchor.getString("toolkit"))
        assertEquals("Compose", anchor.getString("widgetType"))
        assertEquals("Compose#0", anchor.getString("canonicalPath"))
        assertNoText(anchor, "Pay")
    }
}
