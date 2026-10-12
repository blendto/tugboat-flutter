package com.tugboat.android.compose

import androidx.activity.ComponentActivity
import androidx.compose.foundation.clickable
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

/** Lazy list items: `CollectionItemInfo` index, else traversal order (native SDK note 6.2). */
@RunWith(RobolectricTestRunner::class)
class ComposeListIdentityTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(RegionRule()).around(compose)

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

    private fun scrollTo(index: Int) {
        compose.runOnIdle { runBlocking { list.scrollToItem(index) } }
        compose.waitForIdle()
    }

    private fun anchorOf(text: String): JSONObject =
        anchorResolver(compose.activity).tapAt(compose.activity, compose.onNodeWithText(text)).anchor()

    @Test
    fun itemsUseCollectionItemInfoAcrossScrolls() {
        showList(withItemInfo = true)
        assertEquals("Compose#0/Scrollable#0/[item:2]/Node#0", anchorOf("Row 2").getString("canonicalPath"))
        scrollTo(20)
        assertEquals("Compose#0/Scrollable#0/[item:21]/Node#0", anchorOf("Row 21").getString("canonicalPath"))
    }

    @Test
    fun withoutItemInfoTheIndexIsTraversalOrderOnScreen() {
        showList(withItemInfo = false)
        assertEquals("Compose#0/Scrollable#0/[item:2]/Node#0", anchorOf("Row 2").getString("canonicalPath"))
        scrollTo(20)
        // Known gap: counted from the first item on screen.
        assertEquals("Compose#0/Scrollable#0/[item:1]/Node#0", anchorOf("Row 21").getString("canonicalPath"))
    }

    @Test
    fun listItemsAreMediumConfidenceAndTextFree() {
        showList(withItemInfo = true)
        val anchor = anchorOf("Row 3")
        assertEquals("medium", anchor.getString("fingerprintConfidence"))
        assertNoText(anchor, "Row 3")
    }
}
