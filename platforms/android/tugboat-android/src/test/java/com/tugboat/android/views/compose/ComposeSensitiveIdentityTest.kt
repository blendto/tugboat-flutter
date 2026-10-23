package com.tugboat.android.views.compose

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.dp
import com.tugboat.android.compose.ComposeMasking
import com.tugboat.android.compose.tugboatSensitive
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * `Modifier.tugboatSensitive()` is mask-only: the same taps resolve to the
 * same target, canonical path, and fingerprint with and without it.
 */
@RunWith(RobolectricTestRunner::class)
class ComposeSensitiveIdentityTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain =
        RuleChain.outerRule(ComposeInstallRule(ComposeMasking.SemanticsBestEffort)).around(compose)

    private val marked = mutableStateOf(false)

    @Test
    fun aSensitiveContainerChangesNoPathTargetOrFingerprint() {
        compose.setContent {
            val mark = if (marked.value) Modifier.tugboatSensitive() else Modifier
            Column {
                Button(onClick = {}) { Text("A") }
                Box(mark.padding(24.dp)) {
                    Button(onClick = {}) { Text("B") }
                }
                Button(onClick = {}) { Text("C") }
            }
        }
        val before = taps()
        assertEquals("Compose#0/Button#0", before.getValue("A").anchor().getString("canonicalPath"))
        assertEquals("Compose#0/Button#1", before.getValue("B").anchor().getString("canonicalPath"))
        assertEquals("Compose#0/Button#2", before.getValue("C").anchor().getString("canonicalPath"))

        compose.runOnUiThread { marked.value = true }
        compose.waitForIdle()
        val after = taps()
        for ((tap, evidence) in before) assertEquals(tap, evidence.toString(), after.getValue(tap).toString())
    }

    @Test
    fun aSensitiveButtonChangesNoPathTargetOrFingerprint() {
        compose.setContent {
            val mark = if (marked.value) Modifier.tugboatSensitive() else Modifier
            Column {
                Button(onClick = {}) { Text("A") }
                Button(onClick = {}, modifier = mark) { Text("B") }
                Button(onClick = {}) { Text("C") }
            }
        }
        val before = taps()
        compose.runOnUiThread { marked.value = true }
        compose.waitForIdle()
        val after = taps()
        for ((tap, evidence) in before) assertEquals(tap, evidence.toString(), after.getValue(tap).toString())
    }

    /** Tap evidence at A, B, C, and (in the container case) the padding left of B. */
    private fun taps(): Map<String, JSONObject> {
        val resolver = anchorResolver(compose.activity)
        val b = compose.onNodeWithText("B").node.boundsInWindow
        return linkedMapOf(
            "A" to resolver.tapAt(compose.activity, compose.onNodeWithText("A")),
            "B" to resolver.tapAt(compose.activity, compose.onNodeWithText("B")),
            "left of B" to resolver.tapEvidence(compose.activity.decor, b.left - 10f, b.center.y).toJson(),
            "C" to resolver.tapAt(compose.activity, compose.onNodeWithText("C")),
        )
    }
}
