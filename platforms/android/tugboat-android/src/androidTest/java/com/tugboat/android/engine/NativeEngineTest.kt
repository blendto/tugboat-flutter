package com.tugboat.android.engine

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Loads the real `libtugboat_engine.so` and talks to the engine through JNI. */
@RunWith(AndroidJUnit4::class)
class NativeEngineTest {
    private val transport = checkNotNull(JniEngineTransport.open()) { "libtugboat_engine.so must load" }

    @After
    fun tearDown() = transport.close()

    @Test
    fun labelHashMatchesTheConformanceFixture() {
        // conformance/fingerprint/label_hash/ascii.json
        val response = submit("""{"type":"fingerprint.labelHash","input":{"value":"Go"}}""")

        assertEquals(EngineStatus.OK, response.status)
        val json = JSONObject(response.text())
        assertEquals("6cc8519b91584e8b", json.getJSONObject("result").getString("hash"))
    }

    @Test
    fun malformedMessagesReportAStatusInsteadOfThrowing() {
        val response = submit("""{"type":""")

        assertEquals(EngineStatus.MALFORMED_MESSAGE, response.status)
        val error = JSONObject(response.text()).getJSONObject("error")
        assertEquals("malformed_message", error.getString("status"))
    }

    @Test
    fun responsesAreCopiedBeforeTheNextSubmit() {
        val first = submit("""{"type":"fingerprint.labelHash","input":{"value":"Go"}}""")
        val firstText = first.text()
        submit("""{"type":"fingerprint.labelHash","input":{"value":"a much longer label value"}}""")

        assertEquals(firstText, first.text())
    }

    @Test
    fun aClosedTransportAnswersInvalidArgument() {
        val closed = checkNotNull(JniEngineTransport.open())
        closed.close()
        val response = closed.submit("{}".toByteArray())

        assertEquals(EngineStatus.INVALID_ARGUMENT, response.status)
        assertTrue(response.json.isEmpty())
    }

    private fun submit(message: String): EngineResponse = transport.submit(message.toByteArray(Charsets.UTF_8))
}
