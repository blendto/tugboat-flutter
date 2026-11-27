package com.tugboat.android.views.compose

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performSemanticsAction
import com.tugboat.android.views.RecordingFacts
import com.tugboat.android.views.facts.FactTypes
import com.tugboat.android.views.factClock
import com.tugboat.android.views.input.FocusFactProducer
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** `focus.kind` from the focused editable semantics node (native SDK note 5). */
@RunWith(RobolectricTestRunner::class)
class ComposeFocusTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(ComposeInstallRule()).around(compose)

    private val facts = RecordingFacts()
    private val focus = FocusFactProducer(factClock(), facts::emit).apply { activate() }

    @Before
    fun setUp() {
        compose.setContent {
            Column {
                TextField(value = "", onValueChange = {}, modifier = Modifier.testTag("field"))
                Button(onClick = {}, modifier = Modifier.testTag("button")) { Text("Next") }
            }
        }
    }

    private fun kinds() = facts.inputs(FactTypes.FOCUS).map { it.getString("kind") }

    @Test
    fun aFocusedTextFieldIsTextInputThroughTheRecheckFrames() {
        val host = composeHost(compose.activity.decor)!!
        focus.onGlobalFocusChanged(null, host)
        compose.onNodeWithTag("field").performSemanticsAction(SemanticsActions.RequestFocus)
        compose.waitForIdle()
        focus.onInput()
        focus.onFrame(compose.activity.decor.findFocus())
        assertEquals("the host's View focus and the field's focus are one settled change", listOf("text_input"), kinds())
    }

    @Test
    fun focusLeavingTheFieldIsOtherAgain() {
        compose.onNodeWithTag("field").performSemanticsAction(SemanticsActions.RequestFocus)
        compose.waitForIdle()
        focus.onInput()
        focus.onFrame(compose.activity.decor.findFocus())
        compose.onNodeWithTag("button").performSemanticsAction(SemanticsActions.RequestFocus)
        compose.waitForIdle()
        focus.onInput()
        focus.onFrame(compose.activity.decor.findFocus())
        assertEquals(listOf("text_input", "other"), kinds())
    }
}
