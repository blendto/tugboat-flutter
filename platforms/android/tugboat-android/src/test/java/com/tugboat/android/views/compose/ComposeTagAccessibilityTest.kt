package com.tugboat.android.views.compose

import androidx.activity.ComponentActivity
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.dp
import com.tugboat.android.compose.ComposeMasking
import com.tugboat.android.compose.tugboatTag
import com.tugboat.android.views.mask.WindowMasks
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * `tugboatTag(tag, accessibility = true)` adds a `testTag` and nothing else
 * Tugboat reads: anchors (fingerprint, canonical path, tag alias) and the
 * structure signature are those of the one-argument call.
 */
@RunWith(RobolectricTestRunner::class)
class ComposeTagAccessibilityTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(ComposeInstallRule(ComposeMasking.SemanticsBestEffort)).around(compose)

    private enum class Variant { OneArg, Off, On }

    private var variant by mutableStateOf(Variant.OneArg)

    private fun Modifier.tagged(tag: String): Modifier =
        when (variant) {
            Variant.OneArg -> tugboatTag(tag)
            Variant.Off -> tugboatTag(tag, accessibility = false)
            Variant.On -> tugboatTag(tag, accessibility = true)
        }

    private val resolver get() = anchorResolver(compose.activity)

    @Test
    fun identityAndStructureAreTheSameWithAndWithoutAccessibility() {
        compose.setContent {
            Column {
                Button(onClick = {}, modifier = Modifier.tagged("checkout.pay")) { Text("Pay") }
                TextField(value = "Ada", onValueChange = {}, modifier = Modifier.tagged("profile.name"))
                Box(Modifier.size(48.dp).tagged("hero").clickable {}) { Text("Hero") }
            }
        }
        val seen = Variant.entries.map { next ->
            variant = next
            compose.waitForIdle()
            val anchors = listOf("Pay", "Ada", "Hero").map { resolver.tapAt(compose.activity, compose.onNodeWithText(it)).anchor().toString() }
            val masks = WindowMasks.compute(compose.activity.window)
            Triple(anchors, masks.structureSignature, masks.rects)
        }
        val tags = seen.first().first.map { JSONObject(it).getJSONObject("fingerprintParts").getString("tag") }
        assertEquals(listOf("checkout.pay", "profile.name", "hero"), tags)
        assertTrue("no semantics masks to compare", seen.first().third.isNotEmpty())
        for ((i, next) in Variant.entries.withIndex()) assertEquals("$next", seen.first(), seen[i])
    }

    /** One node keeps one `testTag` (the first modifier wins); Tugboat's alias is the tugboatTag in both orders. */
    @Test
    fun anAppTestTagOnTheSameNodeLeavesTheAliasToTheTugboatTag() {
        compose.setContent {
            Column {
                Button(onClick = {}, modifier = Modifier.testTag("app.pay").tugboatTag("checkout.pay", accessibility = true)) { Text("Pay") }
                Button(onClick = {}, modifier = Modifier.tugboatTag("checkout.back", accessibility = true).testTag("app.back")) { Text("Back") }
            }
        }
        val pay = resolver.tapAt(compose.activity, compose.onNodeWithText("Pay")).anchor()
        val back = resolver.tapAt(compose.activity, compose.onNodeWithText("Back")).anchor()
        assertEquals("checkout.pay", pay.getJSONObject("fingerprintParts").getString("tag"))
        assertEquals("checkout.back", back.getJSONObject("fingerprintParts").getString("tag"))
        assertEquals("Compose#0/Button#0", pay.getString("canonicalPath"))
        assertEquals("Compose#0/Button#1", back.getString("canonicalPath"))
    }
}
