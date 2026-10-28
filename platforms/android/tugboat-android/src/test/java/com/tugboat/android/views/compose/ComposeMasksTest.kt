package com.tugboat.android.views.compose

import android.widget.Button
import androidx.activity.ComponentActivity
import androidx.compose.foundation.Canvas
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
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.tugboat.android.compose.ComposeMasking
import com.tugboat.android.views.mask.MaskMode
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

/** Compose masks per native SDK note 2.1, both [ComposeMasking] modes, through `WindowMasks`. */
@RunWith(RobolectricTestRunner::class)
abstract class ComposeMasksTest(masking: ComposeMasking) {
    protected val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(ComposeInstallRule(masking)).around(compose)

    protected fun showScreen() {
        compose.setContent {
            Column {
                Text("Account 1234", Modifier.testTag("text"))
                TextField(value = "hunter2", onValueChange = {}, modifier = Modifier.testTag("field"))
                Image(ColorPainter(Color.Red), contentDescription = "logo", modifier = Modifier.size(40.dp).testTag("image"))
                Box(Modifier.size(30.dp).semantics { contentDescription = "avatar" }.testTag("described"))
                Image(ColorPainter(Color.Blue), contentDescription = null, modifier = Modifier.size(40.dp).testTag("undescribed"))
                val measurer = rememberTextMeasurer()
                Canvas(Modifier.size(80.dp, 30.dp).testTag("drawn")) { drawText(measurer, "IBAN 0042") }
                AndroidView(factory = { Button(it) }, modifier = Modifier.size(60.dp).testTag("interop"))
            }
        }
    }

    internal fun masks(): WindowMaskResult = WindowMasks.compute(compose.activity.window)

    protected fun boundsOf(tag: String): Rect = compose.onNodeWithTag(tag, useUnmergedTree = true).node.boundsInWindow

    internal fun isMasked(result: WindowMaskResult, tag: String): Boolean = covered(result.rects, boundsOf(tag), compose.activity.decor)
}

/** The default: the Compose host is masked whole, so undescribed images and drawn text cannot leak. */
class ComposeWholeHostMasksTest : ComposeMasksTest(ComposeMasking.WholeHost) {
    @Test
    fun theWholeHostIsMaskedIncludingContentWithoutSemantics() {
        showScreen()
        val result = masks()
        assertFalse(result.failClosed)
        val host = composeHost(compose.activity.decor)!!
        val origin = IntArray(2).also(host::getLocationInWindow)
        val hostBounds = Rect(origin[0].toFloat(), origin[1].toFloat(), (origin[0] + host.width).toFloat(), (origin[1] + host.height).toFloat())
        assertTrue("the host is not masked whole: ${result.rects}", covered(result.rects, hostBounds, compose.activity.decor))
        assertTrue(isMasked(result, "undescribed"))
        assertTrue(isMasked(result, "drawn"))
        assertEquals(MaskMode.WholeHost, result.coverage.mode)
        assertEquals("""{"mode":"wholeHost","reasons":["composeDefault"]}""", result.coverage.toJson().toString())
    }
}

/** The opt-in: semantics masks, with the documented residual leak. */
class ComposeSemanticsMasksTest : ComposeMasksTest(ComposeMasking.SemanticsBestEffort) {
    @Test
    fun textEditableTextDescribedImagesAndInteropAreMaskedAtTheirOwnBounds() {
        showScreen()
        val result = masks()
        assertFalse(result.failClosed)
        for (tag in listOf("text", "image", "described", "interop")) assertTrue("$tag is not masked", isMasked(result, tag))
        assertTrue("text field is not masked", covered(result.rects, compose.onNodeWithTag("field").node.boundsInWindow, compose.activity.decor))
        assertEquals("""{"mode":"precise","reasons":["interop"]}""", result.coverage.toJson().toString())
    }

    @Test
    fun theResidualLeakIsWhatTheReadmeSays() {
        showScreen()
        val result = masks()
        // Documented and accepted by opting in: content without semantics is not masked.
        assertFalse(isMasked(result, "undescribed"))
        assertFalse(isMasked(result, "drawn"))
    }

    @Test
    fun interopTapsResolveAsViews() {
        showScreen()
        val anchor = anchorResolver(compose.activity).tapAt(compose.activity, compose.onNodeWithTag("interop")).anchor()
        assertEquals("view", anchor.getString("toolkit"))
        assertEquals("Button", anchor.getString("widgetType"))
    }
}
