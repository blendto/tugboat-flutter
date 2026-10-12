package com.tugboat.android.views

import com.tugboat.android.views.identity.IdentityHash
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/**
 * The Kotlin fingerprint equals the engine's on every
 * `conformance/fingerprint/identity_parts` vector (Robolectric only for a
 * real `org.json`).
 */
@RunWith(RobolectricTestRunner::class)
class IdentityHashConformanceTest {
    private val fixtures: List<File> =
        File(System.getProperty("tugboat.identityFixtures") ?: "../../../conformance/fingerprint/identity_parts")
            .listFiles { file -> file.extension == "json" }
            .orEmpty()
            .sortedBy { it.name }

    @Test
    fun everyIdentityPartsVectorMatches() {
        assertTrue("no identity_parts fixtures found", fixtures.size >= 13)
        for (file in fixtures) {
            val fixture = JSONObject(file.readText())
            assertEquals(file.name, "fingerprint.identityParts", fixture.getString("kind"))
            val pairs = fixture.getJSONObject("input").getJSONArray("parts")
            val parts = LinkedHashMap<String, String>()
            for (i in 0 until pairs.length()) {
                val pair = pairs.getJSONArray(i)
                parts[pair.getString(0)] = pair.getString(1)
            }
            val expected = fixture.getJSONObject("expected")
            assertEquals(file.name, expected.getString("canonicalString"), IdentityHash.canonicalString(parts))
            assertEquals(file.name, expected.getString("fingerprint"), IdentityHash.fingerprint(parts))
        }
    }

    @Test
    fun loneSurrogatesHashAsReplacementCharacterLikeDart() {
        assertEquals(
            IdentityHash.fingerprint(mapOf("k" to "�")),
            IdentityHash.fingerprint(mapOf("k" to "\uD800")),
        )
    }
}
