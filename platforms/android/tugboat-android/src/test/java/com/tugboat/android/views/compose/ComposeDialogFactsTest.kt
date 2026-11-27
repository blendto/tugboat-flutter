package com.tugboat.android.views.compose

import android.app.Dialog
import android.view.View
import android.view.Window
import android.view.inspector.WindowInspector
import androidx.activity.ComponentActivity
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.window.Dialog
import androidx.lifecycle.findViewTreeLifecycleOwner
import com.tugboat.android.views.DialogHarness
import com.tugboat.android.views.overlay.OverlayWindowRoots
import com.tugboat.android.views.tapAnchor
import com.tugboat.android.views.tapThrough
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Compose dialog windows (`Dialog`, material3 `ModalBottomSheet`: both
 * `ComponentDialog`s) through the Views adapter: a tap resolves through the
 * Compose region under the activity's route, and a dialog text field
 * reports `text_input` once its window has focus. Also run on the floor of
 * the tested Compose range (`-Ptugboat.composeBom=2024.09.00`).
 */
@RunWith(RobolectricTestRunner::class)
class ComposeDialogFactsTest {
    // Before the activity launches, so the adapter sees it created and resumed.
    private val harness = DialogHarness()
    private val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(ComposeInstallRule()).around(compose)

    @After
    fun stop() = harness.stop()

    @Test
    fun aComposeDialogTapIsAComposeAnchorUnderTheActivityRoute() {
        compose.setContent {
            Dialog(onDismissRequest = {}) { Button(onClick = {}, modifier = Modifier.testTag("ok")) { Text("OK") } }
        }
        val window = discoverDialog()

        tapAt(window, "ok")

        val anchor = harness.pointerUps().single().tapAnchor()
        assertEquals("compose", anchor.getString("toolkit"))
        assertEquals(ComponentActivity::class.java.name, anchor.getJSONObject("fingerprintParts").getString("routeKey"))
        assertEquals("Compose#0/Button#0", anchor.getString("canonicalPath"))
    }

    @OptIn(ExperimentalMaterial3Api::class)
    @Test
    fun aModalBottomSheetTapIsAComposeAnchor() {
        compose.setContent {
            ModalBottomSheet(onDismissRequest = {}, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
                Button(onClick = {}, modifier = Modifier.testTag("pay")) { Text("Pay") }
            }
        }
        val window = discoverDialog()

        tapAt(window, "pay")

        val anchor = harness.pointerUps().single().tapAnchor()
        assertEquals("compose", anchor.getString("toolkit"))
        assertEquals(ComponentActivity::class.java.name, anchor.getJSONObject("fingerprintParts").getString("routeKey"))
    }

    @Test
    fun aDialogTextFieldIsTextInputOnceItsWindowHasFocus() {
        compose.setContent {
            Dialog(onDismissRequest = {}) { TextField(value = "", onValueChange = {}, modifier = Modifier.testTag("field")) }
        }
        val window = discoverDialog()

        compose.runOnIdle { window.callback.onWindowFocusChanged(true) }
        compose.onNodeWithTag("field").performSemanticsAction(SemanticsActions.RequestFocus)
        compose.waitForIdle()

        val kinds = compose.runOnIdle {
            harness.drainFacts().filter { it.first == "focus" }.map { it.second.getString("kind") }
        }
        assertEquals(listOf("text_input"), kinds)
    }

    /** The activity window loses focus to the shown dialog; returns the dialog's window, facts drained. */
    private fun discoverDialog(): Window {
        compose.waitForIdle()
        return compose.runOnIdle {
            val activity = compose.activity
            activity.window.callback.onWindowFocusChanged(false)
            assertEquals(1, harness.adapter.dialogSessionCount(activity))
            harness.drainFacts()
            val tokens = OverlayWindowRoots.ownerTokens(activity.window)
            val root: View = WindowInspector.getGlobalWindowViews().single { OverlayWindowRoots.isOwnedDialogRoot(it, tokens) }
            (root.findViewTreeLifecycleOwner() as Dialog).window!!
        }
    }

    private fun tapAt(window: Window, tag: String) {
        val center = compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInWindow.center
        compose.runOnIdle { tapThrough(window, center.x, center.y) }
    }
}
