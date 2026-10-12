package com.tugboat.android.compose

import android.widget.Button
import androidx.activity.ComponentActivity
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.ColorPainter
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.tugboat.android.views.mask.MaskRect
import com.tugboat.android.views.mask.WindowMaskResult
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

/** Mask sources per native SDK note 2.1, Compose row, through the Views adapter's `WindowMasks`. */
@RunWith(RobolectricTestRunner::class)
class ComposeMasksTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(RegionRule()).around(compose)

    @Before
    fun setUp() {
        compose.setContent {
            Column {
                Text("Account 1234", Modifier.testTag("text"))
                TextField(value = "hunter2", onValueChange = {}, modifier = Modifier.testTag("field"))
                Image(ColorPainter(Color.Red), contentDescription = "logo", modifier = Modifier.size(40.dp).testTag("image"))
                Box(Modifier.size(30.dp).semantics { contentDescription = "avatar" }.testTag("described"))
                Box(Modifier.size(50.dp).testTag("plain"))
                AndroidView(factory = { Button(it) }, modifier = Modifier.size(60.dp).testTag("interop"))
            }
        }
    }

    private fun masks(): WindowMaskResult = WindowMasks.compute(compose.activity.window)

    private fun boundsOf(tag: String): Rect = compose.onNodeWithTag(tag, useUnmergedTree = true).node.boundsInWindow

    private fun covered(rects: List<MaskRect>, bounds: Rect): Boolean {
        val decor = compose.activity.decor
        val w = decor.width.toDouble()
        val h = decor.height.toDouble()
        val slack = 1e-6
        return rects.any {
            it.x * w <= bounds.left + slack && it.y * h <= bounds.top + slack &&
                (it.x + it.width) * w >= bounds.right - slack && (it.y + it.height) * h >= bounds.bottom - slack
        }
    }

    @Test
    fun textEditableTextImagesAndDescribedNodesAreMaskedAtTheirOwnBounds() {
        val result = masks()
        assertFalse(result.failClosed)
        for (tag in listOf("text", "image", "described", "interop")) {
            assertTrue("$tag is not masked: ${result.rects}", covered(result.rects, boundsOf(tag)))
        }
        val field = compose.onNodeWithTag("field").node.boundsInWindow
        assertTrue("text field is not masked", covered(result.rects, field))
    }

    @Test
    fun plainNodesAreNotMaskedAndTheHostIsNotFailClosed() {
        val result = masks()
        val host = composeHost(compose.activity.decor)!!
        val plain = boundsOf("plain")
        val hostBounds = Rect(0f, 0f, host.width.toFloat(), host.height.toFloat())
        assertFalse("the Compose host is masked whole", covered(result.rects, hostBounds))
        assertFalse("a plain node is masked", covered(result.rects, plain))
    }

    @Test
    fun interopTapsResolveAsViews() {
        val evidence = anchorResolver(compose.activity).tapAt(compose.activity, compose.onNodeWithTag("interop"))
        val anchor = evidence.anchor()
        assertEquals("view", anchor.getString("toolkit"))
        assertEquals("Button", anchor.getString("widgetType"))
    }
}
