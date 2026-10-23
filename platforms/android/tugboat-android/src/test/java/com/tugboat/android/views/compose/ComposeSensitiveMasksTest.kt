package com.tugboat.android.views.compose

import androidx.activity.ComponentActivity
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.ColorPainter
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.dp
import com.tugboat.android.compose.ComposeMasking
import com.tugboat.android.compose.tugboatSensitive
import com.tugboat.android.views.mask.WindowMasks
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class ComposeSensitiveMasksTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain =
        RuleChain.outerRule(ComposeInstallRule(ComposeMasking.SemanticsBestEffort)).around(compose)

    @Test
    fun sensitiveNodeIsMaskedWhenSemanticsWouldLeaveItVisible() {
        compose.setContent {
            Column {
                Image(
                    ColorPainter(Color.Red),
                    contentDescription = null,
                    modifier = Modifier.size(40.dp).testTag("plain").tugboatSensitive(),
                )
                Image(
                    ColorPainter(Color.Blue),
                    contentDescription = null,
                    modifier = Modifier.size(40.dp).testTag("sibling"),
                )
            }
        }
        val result = WindowMasks.compute(compose.activity.window)
        assertTrue(isMasked(result, "plain"))
        assertFalse(isMasked(result, "sibling"))
    }

    @Test
    fun sensitiveControlIsMaskedAtItsBounds() {
        compose.setContent {
            Button(onClick = {}, modifier = Modifier.tugboatSensitive().testTag("pay")) {
                Text("Pay")
            }
        }
        val result = WindowMasks.compute(compose.activity.window)
        assertTrue(isMasked(result, "pay"))
    }

    @Test
    fun sensitiveInsideMaskedTextDoesNotRemoveCoverage() {
        compose.setContent {
            Column {
                Text("secret", Modifier.testTag("text").tugboatSensitive())
            }
        }
        val result = WindowMasks.compute(compose.activity.window)
        assertTrue(isMasked(result, "text"))
    }

    private fun isMasked(result: com.tugboat.android.views.mask.WindowMaskResult, tag: String): Boolean =
        covered(result.rects, boundsOf(tag), compose.activity.decor)

    private fun boundsOf(tag: String) = compose.onNodeWithTag(tag, useUnmergedTree = true).node.boundsInWindow
}
