package com.tugboat.android.compose

import com.tugboat.android.compose.semantics.ComposeUiVersion
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The runtime gate on the tested Compose UI range (README "Compose versions"). */
class ComposeUiVersionTest {
    @Test
    fun theTestedRangeIsOnePointSevenToOnePointEight() {
        assertTrue(ComposeUiVersion.isTested("1.7.0"))
        assertTrue(ComposeUiVersion.isTested("1.7.8"))
        assertTrue(ComposeUiVersion.isTested("1.8.3"))
        assertTrue(ComposeUiVersion.isTested("1.8.0-rc01"))
        assertFalse(ComposeUiVersion.isTested("1.6.8"))
        assertFalse(ComposeUiVersion.isTested("1.9.0"))
        assertFalse(ComposeUiVersion.isTested("1.9.0-beta01"))
        assertFalse(ComposeUiVersion.isTested("2.0.0"))
    }

    @Test
    fun missingOrMalformedVersionsAreUnverified() {
        assertFalse(ComposeUiVersion.isTested(null))
        assertFalse(ComposeUiVersion.isTested(""))
        assertFalse(ComposeUiVersion.isTested("1.8"))
        assertFalse(ComposeUiVersion.isTested("one.eight.three"))
    }

    @Test
    fun theVersionIsReadFromTheComposeUiResource() {
        // The tests run on a tested release (the CI matrix covers both ends).
        assertNotNull(ComposeUiVersion.current)
        assertTrue(ComposeUiVersion.current!!, ComposeUiVersion.verified)
    }
}
