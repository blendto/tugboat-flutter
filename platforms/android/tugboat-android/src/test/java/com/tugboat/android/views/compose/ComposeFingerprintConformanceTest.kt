package com.tugboat.android.views.compose

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Button
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import com.tugboat.android.compose.tugboatTag
import com.tugboat.android.views.identity.IdentityHash
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Compose anchors hash with the shared fingerprint (schema v6): each Compose
 * anchor's fingerprints are the `IdentityHash` of its own parts, the hash
 * `IdentityHashConformanceTest` checks against every
 * `conformance/fingerprint/identity_parts` vector.
 */
@RunWith(RobolectricTestRunner::class)
class ComposeFingerprintConformanceTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(ComposeInstallRule()).around(compose)

    @Test
    fun composeAnchorsAreTheSharedHashOfTheirParts() {
        compose.setContent {
            Column {
                Button(onClick = {}) { Text("Save") }
                Switch(checked = true, onCheckedChange = {}, modifier = Modifier.tugboatTag("wifi").testTag("wifiSwitch"))
            }
        }
        val resolver = anchorResolver(compose.activity)
        val anchors = listOf(
            resolver.tapAt(compose.activity, compose.onNodeWithText("Save")).anchor(),
            resolver.tapAt(compose.activity, compose.onNodeWithTag("wifiSwitch")).anchor(),
        )
        for (anchor in anchors) {
            val route = anchor.getJSONObject("fingerprintParts").getString("routeKey")
            val path = anchor.getString("canonicalPath")
            assertEquals(IdentityHash.fingerprint(mapOf("routeKey" to route, "path" to path)), anchor.getString("fingerprint"))
            assertEquals(6, anchor.getInt("schemaVersion"))
        }
        assertEquals("Compose#0/Switch#0", anchors[1].getString("canonicalPath"))
        assertEquals("switch", anchors[1].getString("role"))
        assertEquals(IdentityHash.fingerprint(mapOf("routeKey" to anchors[1].getJSONObject("fingerprintParts").getString("routeKey"), "tag" to "wifi")), anchors[1].getString("tagFingerprint"))
    }
}
