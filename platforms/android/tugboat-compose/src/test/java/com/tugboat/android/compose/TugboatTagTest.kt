package com.tugboat.android.compose

import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.ColorPainter
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.AccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * What `tugboatTag(tag, accessibility = true)` does to the semantics tree:
 * UI tests find the merged control by the tag, and nothing else a test tool
 * or screen reader reads changes. Identity is tested end to end in
 * tugboat-android (`ComposeTagAccessibilityTest`).
 */
@RunWith(RobolectricTestRunner::class)
class TugboatTagTest {
    @get:Rule
    val compose = createComposeRule()

    private enum class Variant { Untagged, OneArg, Off, On }

    private var variant by mutableStateOf(Variant.Untagged)

    private fun Modifier.tagged(tag: String): Modifier =
        when (variant) {
            Variant.Untagged -> this
            Variant.OneArg -> tugboatTag(tag)
            Variant.Off -> tugboatTag(tag, accessibility = false)
            Variant.On -> tugboatTag(tag, accessibility = true)
        }

    private fun showControls() {
        compose.setContent {
            Column {
                Button(onClick = {}, modifier = Modifier.tagged("checkout.pay")) { Text("Pay") }
                Switch(checked = true, onCheckedChange = {}, modifier = Modifier.tagged("settings.wifi"))
                TextField(value = "Ada", onValueChange = {}, label = { Text("Name") }, modifier = Modifier.tagged("profile.name"))
                Image(
                    ColorPainter(Color.Red),
                    contentDescription = "Close",
                    modifier = Modifier.size(40.dp).tagged("dialog.close").clickable {},
                )
            }
        }
    }

    private val controls: List<Pair<String, () -> SemanticsNodeInteraction>> = listOf(
        "checkout.pay" to { compose.onNodeWithText("Pay") },
        "settings.wifi" to { compose.onNode(isToggleable()) },
        "profile.name" to { compose.onNodeWithText("Ada") },
        "dialog.close" to { compose.onNodeWithContentDescription("Close") },
    )

    private fun show(next: Variant) {
        variant = next
        compose.waitForIdle()
    }

    @Test
    fun withAccessibilityTheMergedControlIsFoundByItsTag() {
        showControls()
        show(Variant.On)
        for ((tag, control) in controls) {
            val expected = control().fetchSemanticsNode().id
            assertEquals(tag, expected, compose.onNodeWithTag(tag).fetchSemanticsNode().id)
            assertEquals(tag, expected, compose.onNodeWithTag(tag, useUnmergedTree = true).fetchSemanticsNode().id)
        }
        val pay = compose.onNodeWithTag("checkout.pay").fetchSemanticsNode()
        assertEquals(Role.Button, pay.config.getOrNull(SemanticsProperties.Role))
        assertEquals("Pay", pay.config[SemanticsProperties.Text].single().text)
        assertTrue(SemanticsActions.OnClick in pay.config)
    }

    @Test
    fun withoutAccessibilityNoTestTagIsSet() {
        showControls()
        for (next in listOf(Variant.OneArg, Variant.Off)) {
            show(next)
            for ((tag, _) in controls) compose.onNodeWithTag(tag, useUnmergedTree = true).assertDoesNotExist()
        }
    }

    @Test
    fun labelRoleAndActionsAreTheSameAsUntagged() {
        showControls()
        val untagged = controls.map { (_, control) -> readable(control().fetchSemanticsNode()) }
        assertTrue(untagged.all { SemanticsActions.OnClick.name in it })
        for (next in listOf(Variant.OneArg, Variant.Off, Variant.On)) {
            show(next)
            val tagged = controls.map { (_, control) -> readable(control().fetchSemanticsNode()) }
            assertEquals("$next", untagged, tagged)
        }
    }

    @Test
    fun anEmptyTagSetsNoTestTag() {
        compose.setContent { Button(onClick = {}, modifier = Modifier.tugboatTag("", accessibility = true)) { Text("Pay") } }
        assertNull(compose.onNodeWithText("Pay").fetchSemanticsNode().config.getOrNull(SemanticsProperties.TestTag))
    }

    /** `testTag` does not merge up (Tugboat's key does): a tag on a child is found only in the unmerged tree. */
    @Test
    fun aTagOnAChildOfAMergedControlIsFoundOnlyInTheUnmergedTree() {
        compose.setContent { Button(onClick = {}) { Text("Pay", Modifier.tugboatTag("checkout.pay", accessibility = true)) } }
        compose.onNodeWithTag("checkout.pay").assertDoesNotExist()
        val child = compose.onNodeWithTag("checkout.pay", useUnmergedTree = true).fetchSemanticsNode()
        assertEquals("Pay", child.config[SemanticsProperties.Text].single().text)
        val button = compose.onNodeWithText("Pay").fetchSemanticsNode().config
        assertEquals("checkout.pay", button[TugboatTagKey])
        assertNull(button.getOrNull(SemanticsProperties.TestTag))
    }

    /** One node keeps one `testTag`: the modifier first in the chain wins (recorded in the KDoc and README). */
    @Test
    fun withAnAppTestTagTheFirstModifierInTheChainWins() {
        compose.setContent {
            Column {
                Button(onClick = {}, modifier = Modifier.testTag("app.pay").tugboatTag("checkout.pay", accessibility = true)) { Text("Pay") }
                Button(onClick = {}, modifier = Modifier.tugboatTag("checkout.back", accessibility = true).testTag("app.back")) { Text("Back") }
            }
        }
        val pay = compose.onNodeWithText("Pay").fetchSemanticsNode().config
        val back = compose.onNodeWithText("Back").fetchSemanticsNode().config
        assertEquals("app.pay", pay[SemanticsProperties.TestTag])
        assertEquals("checkout.back", back[SemanticsProperties.TestTag])
        compose.onNodeWithTag("checkout.pay", useUnmergedTree = true).assertDoesNotExist()
        compose.onNodeWithTag("app.back", useUnmergedTree = true).assertDoesNotExist()
        // Tugboat's own key is unaffected by the order.
        assertEquals("checkout.pay", pay[TugboatTagKey])
        assertEquals("checkout.back", back[TugboatTagKey])
    }

    /**
     * What a test tool or screen reader reads of a merged node: every
     * property but the tags, with actions by label (their lambdas change
     * with each composition).
     */
    private fun readable(node: SemanticsNode): Map<String, Any?> =
        node.config
            .filter { (key, _) -> key != SemanticsProperties.TestTag && key != TugboatTagKey }
            .associate { (key, value) -> key.name to if (value is AccessibilityAction<*>) "action:${value.label}" else value }
}
