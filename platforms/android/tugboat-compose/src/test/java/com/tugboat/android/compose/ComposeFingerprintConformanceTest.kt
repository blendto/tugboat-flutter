package com.tugboat.android.compose

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Button
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.onNodeWithText
import com.tugboat.android.views.identity.IdentityHash
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/**
 * Compose anchors hash with the shared fingerprint (schema v6): the hash
 * matches every `conformance/fingerprint/identity_parts` vector, and each
 * Compose anchor's fingerprints are that hash of its own parts.
 */
@RunWith(RobolectricTestRunner::class)
class ComposeFingerprintConformanceTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(RegionRule()).around(compose)

    private val fixtures: List<File> =
        File(System.getProperty("tugboat.identityFixtures") ?: "../../../conformance/fingerprint/identity_parts")
            .listFiles { file -> file.extension == "json" }
            .orEmpty()
            .sortedBy { it.name }

    @Test
    fun everyIdentityPartsVectorMatches() {
        assertTrue("no identity_parts fixtures found", fixtures.size >= 13)
        for (file in fixtures) {
            val fixture = JSONObject(file.readText())
            val pairs = fixture.getJSONObject("input").getJSONArray("parts")
            val parts = LinkedHashMap<String, String>()
            for (i in 0 until pairs.length()) parts[pairs.getJSONArray(i).getString(0)] = pairs.getJSONArray(i).getString(1)
            assertEquals(file.name, fixture.getJSONObject("expected").getString("fingerprint"), IdentityHash.fingerprint(parts))
        }
    }

    @Test
    fun composeAnchorsAreTheSharedHashOfTheirParts() {
        compose.setContent {
            Column {
                Button(onClick = {}) { Text("Save") }
                Switch(checked = true, onCheckedChange = {}, modifier = Modifier.tugboatTag("wifi"))
            }
        }
        val resolver = anchorResolver(compose.activity)
        val anchors = listOf(
            resolver.tapAt(compose.activity, compose.onNodeWithText("Save")).anchor(),
            resolver.tapAt(compose.activity, compose.onNode(SemanticsMatcher.expectValue(TugboatTagKey, "wifi"))).anchor(),
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
