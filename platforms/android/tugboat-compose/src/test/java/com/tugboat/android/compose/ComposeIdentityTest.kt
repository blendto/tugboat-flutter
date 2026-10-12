package com.tugboat.android.compose

import androidx.activity.ComponentActivity
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.dp
import com.tugboat.android.views.identity.IdentityHash
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Compose identity (native SDK note 6, 6.2) through the Views adapter's resolver. */
@RunWith(RobolectricTestRunner::class)
class ComposeIdentityTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(RegionRule()).around(compose)

    @Before
    fun setUp() {
        compose.setContent {
            Column {
                Button(onClick = {}) { Text("Buy now") }
                Button(onClick = {}, modifier = Modifier.testTag("cancel")) { Text("Cancel") }
                Row {
                    Checkbox(checked = false, onCheckedChange = {}, modifier = Modifier.testTag("remember"))
                    Text("Remember me")
                }
                TextField(value = "4111 1111", onValueChange = {}, modifier = Modifier.testTag("card"))
                Box(Modifier.size(48.dp).tugboatTag("hero").testTag("ignored").clickable {})
                Box(Modifier.size(48.dp).testTag("plain").clickable {})
            }
        }
    }

    private val resolver get() = anchorResolver(compose.activity)

    @Test
    fun buttonsAreRoleTokensWithOrdinalsBelowTheHost() {
        val first = resolver.tapAt(compose.activity, compose.onNodeWithText("Buy now")).anchor()
        val second = resolver.tapAt(compose.activity, compose.onNodeWithTag("cancel")).anchor()
        assertEquals("Compose#0/Button#0", first.getString("canonicalPath"))
        assertEquals("Compose#0/Button#1", second.getString("canonicalPath"))
        assertEquals("Button", first.getString("widgetType"))
        assertEquals("button", first.getString("role"))
        assertEquals("compose", first.getString("toolkit"))
        assertEquals(ComponentActivity::class.java.name, first.getJSONObject("fingerprintParts").getString("routeKey"))
        assertEquals("low", first.getString("fingerprintConfidence"))
    }

    @Test
    fun checkboxAndTextFieldTakeTheirTokensAndRoles() {
        val checkbox = resolver.tapAt(compose.activity, compose.onNodeWithTag("remember")).anchor()
        val field = resolver.tapAt(compose.activity, compose.onNodeWithTag("card")).anchor()
        assertEquals("Compose#0/Checkbox#0", checkbox.getString("canonicalPath"))
        assertEquals("checkbox", checkbox.getString("role"))
        assertEquals("Compose#0/TextField#0", field.getString("canonicalPath"))
        assertEquals("textField", field.getString("role"))
        assertTrue(field.getJSONArray("actions").toString().contains("input"))
    }

    @Test
    fun tugboatTagWinsOverTestTagAndLeavesTheStructuralFingerprint() {
        val tagged = resolver.tapAt(compose.activity, compose.onNodeWithTag("ignored")).anchor()
        val plain = resolver.tapAt(compose.activity, compose.onNodeWithTag("plain")).anchor()
        assertEquals("hero", tagged.getJSONObject("fingerprintParts").getString("tag"))
        assertEquals("high", tagged.getString("fingerprintConfidence"))
        val route = ComponentActivity::class.java.name
        assertEquals(IdentityHash.fingerprint(mapOf("routeKey" to route, "tag" to "hero")), tagged.getString("tagFingerprint"))
        assertEquals(
            IdentityHash.fingerprint(mapOf("routeKey" to route, "path" to tagged.getString("canonicalPath"))),
            tagged.getString("fingerprint"),
        )
        // testTag is the alias when there is no tugboatTag.
        assertEquals("plain", plain.getJSONObject("fingerprintParts").getString("tag"))
    }

    @Test
    fun visibleTextNeverEntersIdentity() {
        for (node in listOf(compose.onNodeWithText("Buy now"), compose.onNodeWithTag("card"), compose.onNodeWithTag("remember"))) {
            assertNoText(resolver.tapAt(compose.activity, node), "Buy now", "Cancel", "Remember me", "4111")
        }
    }

    @Test
    fun aTapResolvesAtTheDownPositionAgainstTheCurrentTree() {
        val bounds = compose.onNodeWithTag("cancel").node.boundsInWindow
        val evidence = resolver.tapEvidence(compose.activity.decor, bounds.left + 2f, bounds.top + 2f).toJson()
        assertEquals("Compose#0/Button#1", evidence.anchor().getString("canonicalPath"))
        assertFalse(evidence.has("failureReason"))
    }
}
