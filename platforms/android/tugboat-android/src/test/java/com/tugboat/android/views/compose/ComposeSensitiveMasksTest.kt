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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.ColorPainter
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performScrollToIndex
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

    /** The marked box has no semantics node; the child is found through its layout ancestry. */
    @Test
    fun aDescendantPlacedOutsideTheSensitiveNodeIsMasked() {
        compose.setContent {
            Box(Modifier.fillMaxSize()) {
                Box(Modifier.size(40.dp).tugboatSensitive()) {
                    Box(Modifier.offset(y = 60.dp).size(40.dp).background(Color.Red).clickable {}.testTag("child"))
                }
            }
        }
        val result = masks()
        // Semantics bounds clip the child to its parent, so both areas come from the child's layout position.
        val origin = compose.onNodeWithTag("child", useUnmergedTree = true).node.layoutInfo.coordinates.positionInWindow()
        val (drawn, parent) = with(compose.density) {
            val side = 40.dp.toPx()
            Rect(origin.x, origin.y, origin.x + side, origin.y + side) to
                Rect(origin.x, origin.y - 60.dp.toPx(), origin.x + side, origin.y - 60.dp.toPx() + side)
        }
        assertTrue("the marked box at $parent: ${result.rects}", covered(result.rects, parent, compose.activity.decor))
        assertTrue("the child drawn outside its sensitive parent at $drawn: ${result.rects}", covered(result.rects, drawn, compose.activity.decor))
    }

    @Test
    fun aSensitiveTextIsMaskedOnce() {
        compose.setContent { Text("secret", Modifier.testTag("text").then(mark)) }
        val before = masks()
        assertTrue(isMasked(before, "text"))
        compose.runOnUiThread { marked.value = true }
        compose.waitForIdle()
        val after = masks()
        assertTrue(isMasked(after, "text"))
        assertEquals("the text is masked once, not once as text and again as sensitive: ${after.rects}", before.rects.size, after.rects.size)
    }

    /** `clearAndSetSemantics` drops semantics set inside it on the same node; the mark is not semantics, so both orders mask. */
    @Test
    fun aMarkBesideClearAndSetSemanticsIsMaskedInEitherOrder() {
        compose.setContent {
            Column {
                Box(Modifier.testTag("outer")) {
                    Image(ColorPainter(Color.Red), null, Modifier.size(40.dp).clearAndSetSemantics {}.tugboatSensitive())
                }
                Box(Modifier.testTag("inner")) {
                    Image(ColorPainter(Color.Blue), null, Modifier.size(40.dp).tugboatSensitive().clearAndSetSemantics {})
                }
            }
        }
        val result = masks()
        assertTrue("clearAndSetSemantics outside the mark: ${result.rects}", isMasked(result, "outer"))
        assertTrue("clearAndSetSemantics inside the mark: ${result.rects}", isMasked(result, "inner"))
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

    /**
     * Lazy slots are deactivated and reused while scrolling: the mark
     * unregisters on detach, re-registers on reuse, and gets its coordinates
     * again before the next draw (review 3, m7).
     */
    @Test
    fun marksInReusedLazySlotsAreMasked() {
        compose.setContent {
            LazyColumn(Modifier.fillMaxSize().testTag("list")) {
                items(100) { index ->
                    Box(Modifier.size(40.dp).tugboatSensitive().testTag("row$index")) {
                        Image(ColorPainter(Color.Red), null)
                    }
                }
            }
        }
        assertVisibleRowsMasked(expectFirst = 0)
        // Small steps: rows that leave go to the reuse pool and the next rows take those slots. One jump would compose
        // the new rows before releasing the old ones, so nothing would be reused.
        for (index in 2..60 step 2) {
            compose.onNodeWithTag("list").performScrollToIndex(index)
            compose.waitForIdle()
        }
        assertVisibleRowsMasked(expectFirst = 60)
    }

    private fun assertVisibleRowsMasked(expectFirst: Int) {
        val result = masks()
        val decor = compose.activity.decor
        val visible = (0 until 100).mapNotNull { index ->
            val nodes = compose.onAllNodesWithTag("row$index", useUnmergedTree = true).fetchSemanticsNodes()
            nodes.firstOrNull { it.layoutInfo.isPlaced && it.boundsInWindow.height > 0f && it.boundsInWindow.top < decor.height }
                ?.let { index to it.boundsInWindow }
        }
        assertTrue("row $expectFirst is on screen: ${visible.map { it.first }}", visible.any { it.first == expectFirst })
        assertTrue("several rows are on screen: ${visible.map { it.first }}", visible.size > 5)
        for ((index, bounds) in visible) {
            assertTrue("row$index at $bounds is not masked: ${result.rects}", covered(result.rects, bounds, decor))
        }
    }

    private fun masks(): WindowMaskResult = WindowMasks.compute(compose.activity.window)

    private fun isMasked(result: WindowMaskResult, tag: String): Boolean =
        covered(result.rects, compose.onNodeWithTag(tag, useUnmergedTree = true).node.boundsInWindow, compose.activity.decor)
}
