package com.tugboat.android.views.compose

import androidx.activity.ComponentActivity
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.CollectionItemInfo
import androidx.compose.ui.semantics.collectionItemInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Lazy list items (native SDK note 6.2): `[item:n]` from `CollectionItemInfo`;
 * without it the on-screen order is not identity, so the item has no index.
 */
@RunWith(RobolectricTestRunner::class)
class ComposeListIdentityTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(ComposeInstallRule()).around(compose)

    private val list = LazyListState()

    private fun showList(withItemInfo: Boolean) {
        compose.setContent {
            LazyColumn(Modifier.height(200.dp), state = list) {
                items(50) { index ->
                    val info = if (withItemInfo) Modifier.semantics { collectionItemInfo = CollectionItemInfo(index, 1, 0, 1) } else Modifier
                    Row(info.fillMaxWidth().height(40.dp).clickable {}) { Text("Row $index") }
                }
            }
        }
    }

    /** Scrolls by [px] pixels: rows move on screen, their on-screen order changes. */
    private fun scrollBy(px: Float) {
        compose.runOnIdle { runBlocking { list.scrollBy(px) } }
        compose.waitForIdle()
    }

    private fun anchorOf(text: String): JSONObject =
        anchorResolver(compose.activity).tapAt(compose.activity, compose.onNodeWithText(text)).anchor()

    @Test
    fun collectionItemInfoGivesAStableMediumConfidenceIndex() {
        showList(withItemInfo = true)
        val before = anchorOf("Row 3")
        assertEquals("Compose#0/Scrollable#0/[item:3]/Node#0", before.getString("canonicalPath"))
        assertEquals("medium", before.getString("fingerprintConfidence"))
        scrollBy(80f)
        assertEquals(before.getString("fingerprint"), anchorOf("Row 3").getString("fingerprint"))
        assertNoText(before, "Row 3")
    }

    @Test
    fun withoutItemInfoTheRowHasNoIndexAndKeepsItsFingerprintWhileScrolling() {
        showList(withItemInfo = false)
        val before = anchorOf("Row 3")
        assertEquals("Compose#0/Scrollable#0/[item]/Node#0", before.getString("canonicalPath"))
        assertEquals("low", before.getString("fingerprintConfidence"))
        scrollBy(80f)
        assertEquals(before.getString("fingerprint"), anchorOf("Row 3").getString("fingerprint"))
    }
}
