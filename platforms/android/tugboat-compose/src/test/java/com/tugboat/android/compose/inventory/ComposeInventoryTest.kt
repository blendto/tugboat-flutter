package com.tugboat.android.compose.inventory

import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import com.tugboat.android.compose.semantics.SemanticsAccess
import com.tugboat.android.toolkit.InventoryTier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class ComposeInventoryTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun theWalkStopsBuildingAtTheLimitButCountsEveryNode() {
        val host = show(FrameLayout.LayoutParams.MATCH_PARENT) {
            Column { repeat(5) { Button(onClick = {}) { Text("Item $it") } } }
        }

        val inventory = ComposeInventory.of(host, SemanticsAccess.Default.mergedRoot(host), limit = 2)

        assertEquals(2, inventory.entries.size)
        assertEquals(5, inventory.total)
        assertTrue(inventory.entries.all { it.tier == InventoryTier.Interactive })
    }

    @Test
    fun theLargeTextThresholdIsAFractionOfTheWindowNotTheHost() {
        // The text fills its 25 px host but covers well under 2% of the window.
        val host = show(25) { Text("Small", Modifier.fillMaxSize()) }
        val window = host.rootView
        assertTrue(25.0 * 25.0 / (window.width.toDouble() * window.height.toDouble()) < 0.02)

        val inventory = ComposeInventory.of(host, SemanticsAccess.Default.mergedRoot(host), limit = 500)

        assertEquals(0, inventory.total)
        assertEquals(emptyList<Any>(), inventory.entries)
    }

    /** Shows [content] in a ComposeView of [sizePx] inside a Views layout; returns its Compose host. */
    private fun show(sizePx: Int, content: @Composable () -> Unit): View {
        compose.activityRule.scenario.onActivity { activity ->
            val view = ComposeView(activity).apply { setContent(content) }
            activity.setContentView(FrameLayout(activity).apply { addView(view, FrameLayout.LayoutParams(sizePx, sizePx)) })
        }
        compose.waitForIdle()
        return composeHost(compose.activity.window.decorView) ?: error("no Compose host")
    }

    private fun composeHost(view: View): View? {
        if (view is ViewRootForTest) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) composeHost(view.getChildAt(i))?.let { return it }
        }
        return null
    }
}
