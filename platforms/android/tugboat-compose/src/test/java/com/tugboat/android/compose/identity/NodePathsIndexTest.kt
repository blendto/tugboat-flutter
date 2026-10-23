package com.tugboat.android.compose.identity

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.CollectionInfo
import androidx.compose.ui.semantics.CollectionItemInfo
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.collectionInfo
import androidx.compose.ui.semantics.collectionItemInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.dp
import com.tugboat.android.compose.semantics.NodeRules
import com.tugboat.android.compose.semantics.SemanticsAccess
import com.tugboat.android.toolkit.RegionHit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Tap and inventory paths come from [NodePaths.index]; pinned on a fixture tree to the values the old tap path gave. */
@RunWith(RobolectricTestRunner::class)
class NodePathsIndexTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun tapAndIndexPathsArePinned() {
        compose.setContent {
            Column {
                Button(onClick = {}) { Text("A") }
                Button(onClick = {}) { Text("B") }
                Text("Title")
                Row {
                    Checkbox(checked = false, onCheckedChange = {})
                    Text("Label")
                }
                // Not kept, but a collection: its children are items.
                Column(Modifier.semantics { collectionInfo = CollectionInfo(rowCount = 3, columnCount = 1) }) {
                    Box(Modifier.semantics { collectionItemInfo = CollectionItemInfo(0, 1, 0, 1) }) {
                        Button(onClick = {}) { Text("Row 0") }
                    }
                    Button(onClick = {}) { Text("Row 1") }
                    Text("Row 2")
                }
                LazyColumn(Modifier.height(120.dp)) {
                    items(3) { Button(onClick = {}) { Text("Lazy $it") } }
                }
            }
        }
        compose.waitForIdle()
        val host = (compose.onNodeWithText("Title").fetchSemanticsNode().root as ViewRootForTest).view
        val root = SemanticsAccess.Default.mergedRoot(host)
        if (root == null) return fail("no semantics root")

        val index = NodePaths.index(root)
        // Pinned from NodePaths.build (the tap path before m-3) on this tree.
        assertEquals(
            listOf(
                "Button#0|false", "Button#1|false", "Checkbox#0|false", "Node#0|false", "Node#1|false",
                "Scrollable#0/[item]/Button#0|false", "Scrollable#0/[item]/Button#0|false",
                "Scrollable#0/[item]/Button#0|false", "Scrollable#0|false", "[item:0]/Button#0|true", "[item:0]|true",
                "[item]/Button#0|false", "[item]/Node#0|false",
                // The unkept collection Column itself: no segment of its own.
                "|false",
            ),
            index.values.map { it.segments.joinToString("/") + "|" + it.inListItem }.sorted(),
        )
        assertEquals(placed(root).map { it.id }.toSet(), index.keys)
        val taps = PINNED_TAPS.keys.associateWith { label ->
            val center = compose.onNodeWithText(label).fetchSemanticsNode().boundsInRoot.center
            (NodeTargets.at(root, center.x, center.y) as? RegionHit.Target)?.path?.joinToString("/")
        }
        assertEquals(PINNED_TAPS, taps)
    }

    /** Every node below [root] that is not excluded, with its subtree. */
    private fun placed(root: SemanticsNode): List<SemanticsNode> {
        val out = ArrayList<SemanticsNode>()
        fun visit(node: SemanticsNode) {
            if (NodeRules.isExcluded(node)) return
            out += node
            node.children.forEach(::visit)
        }
        root.children.forEach(::visit)
        return out
    }

    private companion object {
        /** Labels (test-only reads) to tap paths. */
        val PINNED_TAPS = mapOf(
            "A" to "Button#0",
            "B" to "Button#1",
            "Title" to "Node#0",
            "Label" to "Node#1",
            "Row 0" to "[item:0]/Button#0",
            "Row 1" to "[item]/Button#0",
            "Row 2" to "[item]/Node#0",
            "Lazy 0" to "Scrollable#0/[item]/Button#0",
            "Lazy 1" to "Scrollable#0/[item]/Button#0",
        )
    }
}
