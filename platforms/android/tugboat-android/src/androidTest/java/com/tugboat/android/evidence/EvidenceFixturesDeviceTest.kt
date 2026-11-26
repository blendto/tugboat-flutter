package com.tugboat.android.evidence

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.tugboat.android.engine.EngineStatus
import com.tugboat.android.engine.JniEngineTransport
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Every `conformance/evidence` fixture (packaged as assets), rebuilt as the
 * Kotlin values a host passes and encoded by [EngineEvidenceEncoder], through
 * the real engine: the recorded `data` must equal `expected.data`, key order
 * included. This covers the fixtures whose input the encoder elides
 * (`EvidenceConformanceTest.ELIDED`), and the `jsonText` fixtures through
 * the HTTP-adapter body path ([com.tugboat.android.adapter.HttpErrorBody],
 * what `tugboat-okhttp` passes). Runs as the C++ runner does: a fresh
 * engine, `engine.configure`, `session.start` at 0, then the message.
 */
@RunWith(AndroidJUnit4::class)
class EvidenceFixturesDeviceTest {
    private val fixtures: List<EvidenceFixture> by lazy {
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        val files = listOf("external_event", "network_call").flatMap { dir ->
            assets.list(dir).orEmpty().filter { it.endsWith(".json") }.map { name ->
                "$dir/$name" to assets.open("$dir/$name").bufferedReader().use { it.readText() }
            }
        }
        EvidenceFixture.load(files)
    }

    @Test
    fun theRealEngineRecordsEachFixturesExpectedData() {
        val run = fixtures.filter { it.notForKotlinHost() == null }
        assertTrue("fixtures are packaged", run.size >= 80)
        // jsonText bodies go through the HTTP-adapter body path (HttpErrorBody, tugboat-okhttp).
        assertTrue("jsonText fixtures run", run.count { it.input.optJSONObject("errorResponseBody")?.has("jsonText") == true } >= 10)
        val failures = run.mapNotNull { fixture -> mismatch(fixture) }
        assertEquals(failures.joinToString("\n"), 0, failures.size)
    }

    /** Null when the engine recorded the expected data. */
    private fun mismatch(fixture: EvidenceFixture): String? {
        val engine = checkNotNull(JniEngineTransport.open()) { "libtugboat_engine.so must load" }
        try {
            submit(engine, CONFIGURE)
            submit(engine, SESSION_START)
            val message = "{\"type\":\"${fixture.kind}\",\"at\":{\"monoUs\":${fixture.atMonoUs()}},\"input\":${fixture.encode()}}"
            val response = JSONObject(submit(engine, message))
            val records = response.getJSONArray("records")
            val actual = if (records.length() == 0) "null" else records.getJSONObject(0).getJSONObject("event").get("data").toString()
            val expected = fixture.expectedData.toString()
            return if (actual == expected) null else "${fixture.path}\n  expected $expected\n  actual   $actual"
        } catch (failure: Exception) {
            return "${fixture.path}: $failure"
        } finally {
            engine.close()
        }
    }

    private fun submit(engine: JniEngineTransport, message: String): String {
        val response = engine.submit(message.toByteArray(Charsets.UTF_8))
        check(response.status == EngineStatus.OK) { "${response.status.wireName}: ${response.text()}" }
        return response.text()
    }

    private companion object {
        // As core/session-engine/tests/conformance/evidence_runner.cpp.
        const val CONFIGURE =
            """{"type":"engine.configure","input":{"host":{"app":{"name":"Example App","version":"2.4.0","buildNumber":"240","installationId":"inst-0001","appId":"com.example.app"},"device":{"id":"device-0001","platform":"android","screenSize":{"width":412.0,"height":915.0},"screenDensity":2.625,"screenDpi":420,"screenPixelDensity":2.625},"ip":{"ip":"203.0.113.7"},"locale":{},"configuredUserId":null}}}"""
        const val SESSION_START =
            """{"type":"session.start","at":{"monoUs":0,"wallUs":1781827200000000},"input":{"viewport":{"width":412.0,"height":915.0},"platform":"android","sessionEpoch":0}}"""
    }
}
