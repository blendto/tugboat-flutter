package com.tugboat.android.views.compose

import androidx.activity.ComponentActivity
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.offset
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import com.tugboat.android.compose.ComposeMasking
import com.tugboat.android.views.mask.WindowMasks
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Mid-animation: Compose lays out every frame, so layout geometry is where
 * the content is drawn now. Masks follow it without failing closed.
 */
@RunWith(RobolectricTestRunner::class)
class ComposeAnimationMasksTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(ComposeInstallRule(ComposeMasking.SemanticsBestEffort)).around(compose)

    private val moved = mutableStateOf(false)

    @Test
    fun masksFollowAnimatedTextMidAnimation() {
        compose.setContent {
            val x by animateDpAsState(if (moved.value) 200.dp else 0.dp, tween(durationMillis = 1_000), label = "x")
            Text("Balance 9,000", Modifier.offset(x = x).testTag("moving"))
        }
        compose.waitForIdle()
        compose.mainClock.autoAdvance = false
        val start = drawnBounds()
        compose.runOnUiThread {
            moved.value = true
            Snapshot.sendApplyNotifications()
        }
        repeat(30) { compose.mainClock.advanceTimeByFrame() }
        val now = drawnBounds()
        assertTrue("the text has not moved yet: $start -> $now", now.left > start.left)
        assertTrue("the text is no longer animating: $now", now.left < start.left + 200f * compose.density.density)

        val result = WindowMasks.compute(compose.activity.window)
        assertFalse(result.failClosed)
        assertTrue("the mask does not follow the text: ${result.rects}", covered(result.rects, now, compose.activity.decor))
    }

    /**
     * Where the text is drawn: its unclipped layout box. Its parent wraps the
     * text's resting size and does not clip, so the moving text draws outside
     * the parent, where its clipped semantics bounds are empty.
     */
    private fun drawnBounds(): Rect {
        val node = compose.onNodeWithTag("moving").node
        val origin = node.positionInWindow
        return Rect(origin.x, origin.y, origin.x + node.size.width, origin.y + node.size.height)
    }
}
