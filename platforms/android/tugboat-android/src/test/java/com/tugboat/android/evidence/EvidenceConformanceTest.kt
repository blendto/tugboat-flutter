package com.tugboat.android.evidence

import com.tugboat.android.adapter.HttpErrorBody
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/**
 * Every `conformance/evidence` fixture, rebuilt as the Kotlin values a host
 * passes ([EvidenceFixture]), must encode to the fixture's engine input.
 * The device test (`EvidenceFixturesDeviceTest`) runs the same values
 * through the real engine against `expected.data`.
 */
@RunWith(RobolectricTestRunner::class)
class EvidenceConformanceTest {
    private val fixtures: List<EvidenceFixture> by lazy {
        val root = File(checkNotNull(System.getProperty("tugboat.evidenceFixtures")) { "tugboat.evidenceFixtures is not set" })
        val files = root.walkTopDown().filter { it.isFile && it.extension == "json" }.map { it.relativeTo(root).path to it.readText() }
        EvidenceFixture.load(files.toList())
    }

    @Test
    fun everyElidedFixtureExists() {
        assertEquals(ELIDED.keys, ELIDED.keys.filter { name -> fixtures.any { it.name == name } }.toSet())
    }

    @Test
    fun everyFixtureIsLoaded() {
        assertTrue(fixtures.count { it.isExternalEvent } >= 30)
        assertTrue(fixtures.count { it.isNetworkCall } >= 50)
    }

    @Test
    fun jsonTextFixturesAreSentThroughTheAdapterBodyPath() {
        val jsonText = fixtures.filter { it.notForKotlinHost() == null && it.input.optJSONObject("errorResponseBody")?.has("jsonText") == true }
        assertTrue(jsonText.size >= 10)
        jsonText.forEach { assertTrue(it.path, it.hostCall().errorResponseBody is HttpErrorBody) }
    }

    @Test
    fun theEncoderSendsEachFixturesInput() {
        val mismatches = fixtures.filter { it.notForKotlinHost() == null }.mapNotNull { fixture ->
            val expected = canonical(expectedInput(fixture))
            val actual = canonical(JSONObject(fixture.encode()).apply { if (!fixture.input.has("atMonoUs")) remove("atMonoUs") })
            when {
                fixture.name in ELIDED -> if (expected != actual) null else "${fixture.path} is listed as elided but encodes as its input"
                expected == actual -> null
                else -> "${fixture.path}\n  expected $expected\n  actual   $actual"
            }
        }
        assertEquals(mismatches.joinToString("\n"), 0, mismatches.size)
    }

    /**
     * The fixture input as the manual API sends it: no body below status 400
     * (never read), and no parameters for an empty map.
     */
    private fun expectedInput(fixture: EvidenceFixture): JSONObject {
        val input = JSONObject(fixture.input.toString())
        if (fixture.isNetworkCall && input.optInt("statusCode", 0) < EngineEvidenceEncoder.ERROR_STATUS) input.remove("errorResponseBody")
        if (fixture.isNetworkCall && input.optJSONObject("errorResponseBody")?.opt("value") == JSONObject.NULL) input.remove("errorResponseBody")
        if (input.optJSONObject("parameters")?.getJSONArray("map")?.length() == 0) input.remove("parameters")
        return input
    }

    /**
     * Objects by key (the engine reads message fields and tags by name; map
     * entries and items keep their order, as arrays), integers as `Long`, and
     * a `double` tag's number as `Double`.
     */
    private fun canonical(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().sorted().map { key ->
            val item = value.get(key)
            key to if (key == "double" && item is Number) item.toDouble() else canonical(item)
        }.toList()
        is JSONArray -> List(value.length()) { canonical(value.get(it)) }
        is Int -> value.toLong()
        JSONObject.NULL -> null
        else -> value
    }

    private companion object {
        /**
         * Fixtures whose input the encoder writes differently, by the
         * mandatory bounds of evidence-messages.md sections 4.4 and 4.5 (the
         * same record): the device test checks their engine output.
         */
        val ELIDED = mapOf(
            "collection-budget-shared" to "nested invalid keys folded into one nonStringKeys run",
            "collection-items-257" to "the item budget stops the list at its 257th item with omitted",
            "transform-results" to "an invalid key is a nonStringKeys run",
            "depth-5-dropped" to "a value at depth 5 is sent unsupported (required bound)",
            "omitted-items-stand-in" to "the stand-ins are sent as the unsupported values they stand for",
            "run-counts-towards-64" to "64 top-level entries, then omitted",
            "string-1024-and-1025" to "a string over 1024 units is sent unsupported",
            "top-level-invalid-keys" to "invalid top-level keys are nonStringKeys runs",
            "top-level-key-length-surrogates" to "the 129-unit key is a nonStringKeys run",
            "unsupported-values" to "nested invalid keys folded into one nonStringKeys run",
            "json-body-129-items" to "128 items, then omitted",
            "json-body-depth-5-kept-6-unsupported" to "a collection at depth 6 is sent unsupported (required bound)",
            "json-body-non-string-keys" to "128 entries, then omitted",
            "json-body-cut-keys-repeat" to "the first 4097-unit key passes the text budget: sent with null, then the body stops",
            "text-body-multibyte-boundary" to "the text body is cut to 4097 units",
            "text-body-surrogate-pair-boundary" to "the text body is cut to 4097 units, keeping the pair",
        )
    }
}
