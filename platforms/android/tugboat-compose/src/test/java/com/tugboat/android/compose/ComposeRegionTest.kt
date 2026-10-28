package com.tugboat.android.compose

import android.view.View
import android.view.ViewGroup
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.ColorPainter
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import com.tugboat.android.compose.semantics.SemanticsAccess
import com.tugboat.android.toolkit.InventoryTier
import com.tugboat.android.toolkit.MaskCoverageReason
import com.tugboat.android.toolkit.RegionHit
import com.tugboat.android.toolkit.RegionMasks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The Compose region's own answers (the Views adapter's use of them is
 * tested in tugboat-android): masking mode, the version gate that overrides
 * the opt-in, and the semantics-owner-unavailable fallback.
 */
@RunWith(RobolectricTestRunner::class)
class ComposeRegionTest {
    @get:Rule
    val compose = createComposeRule()

    private lateinit var host: View

    @Before
    fun setUp() {
        compose.setContent {
            Column {
                Button(onClick = {}) { Text("Pay") }
                Image(ColorPainter(Color.Red), contentDescription = "logo")
            }
        }
        compose.waitForIdle()
        host = (compose.onNodeWithText("Pay").fetchSemanticsNode().root as ViewRootForTest).view
    }

    @Test
    fun theDefaultMasksTheWholeHost() {
        val masks = ComposeRegion(ComposeMasking.WholeHost).masks(host)
        assertEquals(MaskCoverageReason.ComposeDefault, (masks as RegionMasks.WholeHost).reason)
    }

    @Test
    fun theOptInMasksSemanticsNodesWhenTheVersionIsVerified() {
        val masks = ComposeRegion(ComposeMasking.SemanticsBestEffort, versionVerified = { true }).masks(host)
        assertTrue(masks is RegionMasks.Rects)
        assertEquals(2, (masks as RegionMasks.Rects).rects.size)
        assertEquals(emptySet<MaskCoverageReason>(), masks.reasons)
    }

    @Test
    fun anUnverifiedVersionIgnoresTheOptIn() {
        val masks = ComposeRegion(ComposeMasking.SemanticsBestEffort, versionVerified = { false }).masks(host)
        assertEquals(MaskCoverageReason.ComposeVersionUnverified, (masks as RegionMasks.WholeHost).reason)
    }

    @Test
    fun anUnavailableOwnerMasksTheWholeFrameAndAnchorsTheHost() {
        val unavailable = SemanticsAccess { error("semantics owner moved") }
        val region = ComposeRegion(ComposeMasking.SemanticsBestEffort, unavailable, versionVerified = { true })
        val masks = region.masks(host)
        assertEquals(MaskCoverageReason.ComposeOwnerUnavailable, (masks as RegionMasks.WholeFrame).reason)
        assertSame(RegionHit.Unreadable, region.targetAt(host, 10f, 10f))
        assertEquals(emptyList<Any>(), region.scrollablesAt(host, 10f, 10f))
        assertEquals(null, region.focus(host))
    }

    @Test
    fun onlyComposeHostsAreHosts() {
        val region = ComposeRegion(ComposeMasking.WholeHost)
        assertTrue(region.hosts(host))
        assertTrue(!region.hosts(host.parent as ViewGroup))
    }

    @Test
    fun inventoryListsTheInteractiveControlInWholeHostMode() {
        val entries = ComposeRegion(ComposeMasking.WholeHost).inventory(host, limit = 500).entries
        assertTrue(entries.any { it.tier == InventoryTier.Interactive && it.target.actions.isNotEmpty() })
        assertTrue(entries.none { it.target.widgetType.contains("Pay", ignoreCase = true) })
    }

    @Test
    fun inventoryListsTheInteractiveControlInSemanticsMaskingMode() {
        val entries =
            ComposeRegion(ComposeMasking.SemanticsBestEffort, versionVerified = { true }).inventory(host, limit = 500).entries
        assertTrue(entries.any { it.tier == InventoryTier.Interactive && it.target.actions.isNotEmpty() })
        assertTrue(entries.none { it.target.path.any { segment -> segment.contains("Pay") } })
    }
}
