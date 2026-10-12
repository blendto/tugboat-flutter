package com.tugboat.android.compose

import android.graphics.RectF
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import com.tugboat.android.toolkit.ToolkitRegions
import com.tugboat.android.views.mask.MaskRect
import com.tugboat.android.views.mask.WindowMasks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * A `ComposeView` inside a Views screen routes through the Compose region:
 * Compose taps get Compose anchors below the host's Views path, and masks
 * come from its semantics instead of the Views fail-closed host rule.
 */
@RunWith(RobolectricTestRunner::class)
class ComposeInViewsTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()

    private val regionRule = RegionRule()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(regionRule).around(compose)

    private lateinit var label: TextView
    private lateinit var composeView: ComposeView

    @Before
    fun setUp() {
        compose.activityRule.scenario.onActivity { activity ->
            label = TextView(activity).apply {
                text = "Views label"
                isClickable = true
            }
            composeView = ComposeView(activity).apply { setContent { Button(onClick = {}) { Text("Go") } } }
            val screen = LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                addView(label, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 50))
                addView(composeView, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 150))
            }
            activity.setContentView(screen)
        }
        compose.waitForIdle()
    }

    @Test
    fun composeTapsAreComposeAnchorsBelowTheHostsViewsPath() {
        val resolver = anchorResolver(compose.activity)
        val button = resolver.tapAt(compose.activity, compose.onNodeWithText("Go")).anchor()
        assertEquals("compose", button.getString("toolkit"))
        assertEquals("Compose#0/Button#0", button.getString("canonicalPath"))
        val labelBounds = boundsInDecor(label)
        val views = resolver.tapEvidence(compose.activity.decor, labelBounds.centerX(), labelBounds.centerY()).toJson().anchor()
        assertEquals("view", views.getString("toolkit"))
        assertEquals("TextView#0", views.getString("canonicalPath"))
    }

    @Test
    fun masksComeFromSemanticsNotTheFailClosedHostRule() {
        val result = WindowMasks.compute(compose.activity.window)
        assertFalse(result.failClosed)
        assertFalse("the ComposeView is masked whole", result.rects.any { it.covers(normalized(boundsInDecor(composeView))) })
        assertTrue("the Views TextView is not masked", result.rects.any { it.covers(normalized(boundsInDecor(label))) })
        assertTrue("the Compose button text is not masked", result.rects.size >= 2)
    }

    @Test
    fun withoutTheRegionTheComposeHostStaysFailClosed() {
        ToolkitRegions.unregister(regionRule.region)
        val result = WindowMasks.compute(compose.activity.window)
        assertTrue("the ComposeView is not fail-closed", result.rects.any { it.covers(normalized(boundsInDecor(composeView))) })
    }

    private fun boundsInDecor(view: View): RectF {
        val origin = IntArray(2).also(view::getLocationInWindow)
        val decor = IntArray(2).also(compose.activity.decor::getLocationInWindow)
        val left = (origin[0] - decor[0]).toFloat()
        val top = (origin[1] - decor[1]).toFloat()
        return RectF(left, top, left + view.width, top + view.height)
    }

    private fun normalized(rect: RectF): MaskRect {
        val decor = compose.activity.decor
        val width = decor.width.toDouble()
        val height = decor.height.toDouble()
        return MaskRect(rect.left / width, rect.top / height, rect.width() / width, rect.height() / height)
    }

    private fun MaskRect.covers(other: MaskRect): Boolean {
        val slack = 1e-6
        return x <= other.x + slack && y <= other.y + slack &&
            x + width >= other.x + other.width - slack && y + height >= other.y + other.height - slack
    }
}
