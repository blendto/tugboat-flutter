package com.tugboat.android.views.compose

import androidx.activity.ComponentActivity
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.ColorPainter
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import com.tugboat.android.compose.ComposeMasking
import com.tugboat.android.compose.tugboatSensitive
import com.tugboat.android.views.mask.WindowMaskResult
import com.tugboat.android.views.mask.WindowMasks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * `Modifier.tugboatSensitive()` under `SemanticsBestEffort`, the most
 * permissive native configuration: every node chosen below has no text,
 * image role, or description, so only the sensitive mark can mask it.
 */
@RunWith(RobolectricTestRunner::class)
class ComposeSensitiveMasksTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain =
        RuleChain.outerRule(ComposeInstallRule(ComposeMasking.SemanticsBestEffort)).around(compose)

    private val marked = mutableStateOf(false)

    private val mark: Modifier
        get() = if (marked.value) Modifier.tugboatSensitive() else Modifier

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
        val result = masks()
        assertTrue(isMasked(result, "plain"))
        assertFalse(isMasked(result, "sibling"))
    }

    /** The mark on the merging node itself: the whole button, not only its text, is masked. */
    @Test
    fun sensitiveControlIsMaskedAtItsBounds() {
        compose.setContent {
            Button(onClick = {}, modifier = Modifier.tugboatSensitive().testTag("pay")) {
                Text("Pay")
            }
        }
        assertTrue(isMasked(masks(), "pay"))
    }

    /** The mark on a child merged into a button: masks read the unmerged tree, where the child is its own node. */
    @Test
    fun sensitiveChildMergedIntoAButtonIsMasked() {
        compose.setContent {
            Button(onClick = {}) {
                Box(Modifier.size(24.dp).background(Color.Red).tugboatSensitive().testTag("chip"))
            }
        }
        assertTrue(isMasked(masks(), "chip"))
    }

    @Test
    fun aDescendantPlacedOutsideTheSensitiveNodeIsMasked() {
        compose.setContent {
            Box(Modifier.size(40.dp).tugboatSensitive().testTag("parent")) {
                Box(Modifier.offset(y = 60.dp).size(40.dp).background(Color.Red).clickable {}.testTag("child"))
            }
        }
        val result = masks()
        assertTrue(isMasked(result, "parent"))
        assertTrue("the child drawn outside its sensitive parent: ${result.rects}", isMasked(result, "child"))
    }

    @Test
    fun aSensitiveTextIsMaskedOnce() {
        compose.setContent { Text("secret", Modifier.testTag("text").then(mark)) }
        val before = masks()
        assertTrue(isMasked(before, "text"))
        compose.runOnUiThread { marked.value = true }
        compose.waitForIdle()
        assertEquals("no duplicate and no removed rect", before.rects, masks().rects)
    }

    @Test
    fun aChildFillingItsSensitiveParentAddsNoSecondRect() {
        compose.setContent {
            Box(Modifier.size(40.dp).then(mark).testTag("parent")) {
                Box(Modifier.fillMaxSize().clickable {})
            }
        }
        val before = masks()
        assertFalse(isMasked(before, "parent"))
        compose.runOnUiThread { marked.value = true }
        compose.waitForIdle()
        val after = masks()
        assertTrue(isMasked(after, "parent"))
        assertEquals("one rect for the parent, none for the child inside it: ${after.rects}", before.rects.size + 1, after.rects.size)
    }

    private fun masks(): WindowMaskResult = WindowMasks.compute(compose.activity.window)

    private fun isMasked(result: WindowMaskResult, tag: String): Boolean =
        covered(result.rects, compose.onNodeWithTag(tag, useUnmergedTree = true).node.boundsInWindow, compose.activity.decor)
}
