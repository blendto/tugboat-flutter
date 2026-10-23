package com.tugboat.android.views.compose

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.positionInWindow
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

    /**
     * A marked lazy row: without a semantics node of its own the row is not
     * a list item, so each button stays its own `[item]` (review B3).
     */
    @Test
    fun aSensitiveLazyRowChangesNoItemPathOrTarget() {
        compose.setContent {
            val mark = if (marked.value) Modifier.tugboatSensitive() else Modifier
            LazyColumn {
                items(3) { index ->
                    Row(mark) {
                        Button(onClick = {}) { Text("Pay $index") }
                        Button(onClick = {}) { Text("Details $index") }
                    }
                }
            }
        }
        val labels = listOf("Pay 0", "Details 0", "Details 1")
        val before = labels.associateWith { tap(it) }
        assertEquals("Compose#0/Scrollable#0/[item]/Button#0", before.getValue("Details 0").anchor().getString("canonicalPath"))
        compose.runOnUiThread { marked.value = true }
        compose.waitForIdle()
        for (label in labels) assertEquals(label, before.getValue(label).toString(), tap(label).toString())
    }

    /** A button drawn below its 40 dp marked parent still resolves as the button (review B3). */
    @Test
    fun aChildDrawnOutsideTheMarkedBoxStillResolvesAsItself() {
        compose.setContent {
            val mark = if (marked.value) Modifier.tugboatSensitive() else Modifier
            // The outer box sizes the host past the marked box (`setContent` wraps its content).
            Box(Modifier.fillMaxSize()) {
                Box(Modifier.size(40.dp).then(mark)) {
                    Button(onClick = {}, modifier = Modifier.offset(y = 60.dp)) { Text("Go") }
                }
            }
        }
        val before = tapDrawn("Go")
        assertEquals("Button", before.anchor().getString("widgetType"))
        compose.runOnUiThread { marked.value = true }
        compose.waitForIdle()
        assertEquals(before.toString(), tapDrawn("Go").toString())
    }

    /** A tap at the centre of where [label]'s node is drawn: its semantics bounds are clipped to the 40 dp parent. */
    private fun tapDrawn(label: String): JSONObject {
        val coordinates = compose.onNodeWithText(label).node.layoutInfo.coordinates
        val origin = coordinates.positionInWindow()
        val x = origin.x + coordinates.size.width / 2f
        val y = origin.y + coordinates.size.height / 2f
        return anchorResolver(compose.activity).tapEvidence(compose.activity.decor, x, y).toJson()
    }

    private fun tap(label: String): JSONObject = anchorResolver(compose.activity).tapAt(compose.activity, compose.onNodeWithText(label))

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
