package com.tugboat.android.compose.mask

import android.view.View
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import com.tugboat.android.compose.SensitiveMarkers
import com.tugboat.android.compose.semantics.SemanticsAccess
import com.tugboat.android.compose.tugboatSensitive
import com.tugboat.android.toolkit.RegionMasks
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Removing `Modifier.tugboatSensitive()` releases its registry entry and its
 * rect (review 3, m7). Here, not in `tugboat-android`, because the registry
 * is internal to this module.
 */
@RunWith(RobolectricTestRunner::class)
class SensitiveMarkersTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val marked = mutableStateOf(true)

    @Test
    fun removingTheMarkReleasesItsEntryAndItsRect() {
        compose.setContent {
            Box(Modifier.size(40.dp).then(if (marked.value) Modifier.tugboatSensitive() else Modifier))
        }
        val host = composeHost(compose.activity.window.decorView)
        assertEquals(1, host?.let(SensitiveMarkers::registered))
        assertEquals("the mark's rect", 1, host?.let(::rectCount))

        compose.runOnUiThread { marked.value = false }
        compose.waitForIdle()
        assertEquals("the entry is released on detach", 0, host?.let(SensitiveMarkers::registered))
        assertEquals("the rect count drops back", 0, host?.let(::rectCount))
    }

    private fun rectCount(host: View): Int? =
        (ComposeMasks.of(host, SemanticsAccess.Default.unmergedRoot(host)) as? RegionMasks.Rects)?.rects?.size

    private fun composeHost(view: View): View? {
        if (view is ViewRootForTest) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) composeHost(view.getChildAt(i))?.let { return it }
        }
        return null
    }
}
