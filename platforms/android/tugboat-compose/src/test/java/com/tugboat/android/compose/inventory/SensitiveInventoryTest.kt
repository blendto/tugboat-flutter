package com.tugboat.android.compose.inventory

import android.view.View
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import com.tugboat.android.compose.semantics.SemanticsAccess
import com.tugboat.android.compose.tugboatSensitive
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** `Modifier.tugboatSensitive()` adds no semantics node, so scene inventory and its `[item]` dedupe are unchanged (review B3). */
@RunWith(RobolectricTestRunner::class)
class SensitiveInventoryTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val marked = mutableStateOf(false)

    @Test
    fun aSensitiveLazyRowLeavesTheInventoryAndItsDedupeKeysUnchanged() {
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
        val before = inventory()
        assertEquals("one [item] path, listed once: $before", listOf("Scrollable#0/[item]/Button#0 Interactive"), before)
        compose.runOnUiThread { marked.value = true }
        compose.waitForIdle()
        assertEquals(before, inventory())
    }

    private fun inventory(): List<String> {
        val host = composeHost(compose.activity.window.decorView) ?: return emptyList()
        val inventory = ComposeInventory.of(host, SemanticsAccess.Default.mergedRoot(host), limit = 500)
        return inventory.entries.map { "${it.target.path.joinToString("/")} ${it.tier}" } + listOfNotNull(
            "total ${inventory.total}".takeIf { inventory.total != inventory.entries.size },
        )
    }

    private fun composeHost(view: View): View? {
        if (view is ViewRootForTest) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) composeHost(view.getChildAt(i))?.let { return it }
        }
        return null
    }
}
