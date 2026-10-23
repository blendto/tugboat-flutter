package com.tugboat.android.compose

import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class TugboatSensitiveTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun childSensitiveMergesIntoMergedButtonSemantics() {
        compose.setContent {
            Button(onClick = {}) {
                Text("Pay", Modifier.tugboatSensitive())
            }
        }
        val merged = compose.onNodeWithText("Pay").fetchSemanticsNode()
        assertEquals(true, merged.config.getOrNull(TugboatSensitiveKey))
    }
}
