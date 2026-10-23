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
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** [NodePaths.index] gives every node the path [NodePaths.build] (the tap path) gives it. */
@RunWith(RobolectricTestRunner::class)
class NodePathsIndexTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun theIndexEqualsTheTapPathForEveryNode() {
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
        val nodes = placed(root)
        assertTrue(nodes.size > 10)
        for (node in nodes) {
            val built = NodePaths.build(root, node)
            val indexed = index[node.id]
            assertEquals("node ${node.id}", built?.segments, indexed?.segments)
            assertEquals("node ${node.id}", built?.inListItem, indexed?.inListItem)
        }
        val paths = index.values.map { it.segments.joinToString("/") }
        assertTrue(paths.toString(), paths.any { it.startsWith("[item:0]/Button#0") })
        assertTrue(paths.toString(), paths.any { it.startsWith("[item]/Button#0") })
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
}
