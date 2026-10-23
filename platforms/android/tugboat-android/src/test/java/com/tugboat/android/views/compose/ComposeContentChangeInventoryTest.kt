package com.tugboat.android.views.compose

import android.app.Application
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import com.tugboat.android.host.FakeClock
import com.tugboat.android.views.ManualFrames
import com.tugboat.android.views.RecordingSink
import com.tugboat.android.views.ViewsAdapter
import com.tugboat.android.views.context
import com.tugboat.android.views.input.GestureConfig
import com.tugboat.android.views.layOut
import com.tugboat.android.views.navigation.NavigationObservation
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Under the default whole-host masking a Compose screen's structure
 * signature does not change when its semantics do (the masks are one
 * whole-host rectangle). A window with region hosts is therefore never
 * skipped by signature: the new content is inventoried.
 */
@RunWith(RobolectricTestRunner::class)
class ComposeContentChangeInventoryTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(ComposeInstallRule()).around(compose)

    private val sink = RecordingSink()
    private val frames = ManualFrames()
    private var walks = 0
    private lateinit var adapter: ViewsAdapter

    @Before
    fun setUp() {
        NavigationObservation.resetForTests()
        NavigationObservation.setFrameSchedulerForTests(frames)
        adapter = ViewsAdapter(
            application = context as Application,
            sink = sink,
            hostClock = FakeClock(monoUs = 50_000_000),
            frames = frames,
            gesture = GestureConfig(touchSlop = 8.0, panSlop = 16.0, scaleSlop = 16.0),
            emitSceneInventory = true,
            onInventoryWalk = { walks++ },
        ).apply { start() }
    }

    @After
    fun stop() = adapter.stop()

    @Test
    fun changedComposeContentUnderAnUnchangedSignatureIsInventoriedAgain() {
        var loaded by mutableStateOf(false)
        compose.setContent {
            Column {
                if (loaded) {
                    Button(onClick = {}) { Text("Pay") }
                    Button(onClick = {}) { Text("Later") }
                } else {
                    Button(onClick = {}) { Text("Retry") }
                }
            }
        }
        compose.waitForIdle()
        val window = compose.activity.window
        layOut(window.decorView)
        val loading = adapter.masks(window)
        assertTrue(loading.hasRegionHosts)
        adapter.onCapturedFrame(window, loading.structureSignature, loading.hasRegionHosts)

        loaded = true
        compose.waitForIdle()
        layOut(window.decorView)
        val content = adapter.masks(window)
        assertEquals(loading.structureSignature, content.structureSignature)
        adapter.onCapturedFrame(window, content.structureSignature, content.hasRegionHosts)
        frames.runFrame()

        assertEquals(2, walks)
        val inventories = sink.batches.flatten().filter { it.type == "scene.inventory" }.map { JSONObject(it.inputJson) }
        assertEquals(2, inventories.size)
        assertEquals(1, inventories[0].getJSONArray("elements").length())
        assertEquals(2, inventories[1].getJSONArray("elements").length())
        assertNotEquals(inventories[0].toString(), inventories[1].toString())
        assertNoText(inventories[1], "Pay", "Later", "Retry")
    }
}
