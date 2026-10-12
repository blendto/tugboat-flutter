package com.tugboat.android.sdk

import android.app.Application
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.tugboat.android.AppInfo
import com.tugboat.android.CollectorConfig
import com.tugboat.android.TugboatConfig
import com.tugboat.android.capture.BoundaryRect
import com.tugboat.android.capture.CaptureAnswer
import com.tugboat.android.capture.CaptureTimingsMicros
import com.tugboat.android.capture.CapturedFrame
import com.tugboat.android.engine.JniEngineTransport
import com.tugboat.android.host.EngineHost
import com.tugboat.android.host.FrameHandleTable
import com.tugboat.android.host.HostConfig
import com.tugboat.android.host.HostMessages
import com.tugboat.android.host.HttpBody
import com.tugboat.android.host.HttpRequest
import com.tugboat.android.host.HttpSender
import com.tugboat.android.host.SystemHostClock
import com.tugboat.android.host.TransportOutcome
import com.tugboat.android.views.input.GestureConfig
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Contract test (native SDK note section 8): the real engine, driven through
 * the host with the SDK's own `engine.configure`, `session.start`, and
 * `capture.result` builders, must produce collector bodies the collector
 * accepts. Pins the `session_start` body (every required field) and
 * `frameMetadata[].requestedBackend` / `resolvedBackend` =
 * `nativeCpuExperimental`. Only the transport is fake: it records each
 * `http.send` and answers 202.
 */
@RunWith(AndroidJUnit4::class)
class CollectorContractTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
    private val app = AppInfo("Contract", "3.1.4", "314", "com.tugboat.contract", "install-contract")
    private val config = TugboatConfig(CollectorConfig("http://127.0.0.1:9", "key"), app)
    private val frames = FrameHandleTable()
    private val http = RecordingSender()
    private lateinit var host: EngineHost

    @After
    fun tearDown() {
        if (::host.isInitialized) host.close()
    }

    @Test
    fun sessionStartAndFrameUploadsMatchTheCollectorContract() {
        val device = DeviceSnapshot.read(context)
        val metadata = HostMetadata(app, device)
        assertEquals(emptyList<String>(), metadata.missingFields())
        val transport = checkNotNull(JniEngineTransport.open()) { "libtugboat_engine.so must load" }
        host = EngineHost.start(
            HostConfig(config.collector.baseUrl, config.collector.apiKey, app.version, app.buildNumber, app.appId),
            transport,
            frames,
            http = http,
            captures = { request -> answer(request.requestId) },
        )

        host.postUntimed(SessionMessages.ENGINE_CONFIGURE, EngineConfiguration.build(config, metadata, GestureConfig.from(context)).toString())
        host.post(SessionMessages.SESSION_START, SessionMessages.sessionStart(device, metadata, 0), SystemHostClock.now())

        val start = JSONObject(awaitRequest { it.lane == "lifecycle" }.json())
        assertEquals("session_start", start.getString("eventType"))
        val appInfo = start.getJSONObject("appInfo")
        assertEquals("3.1.4", appInfo.getString("version"))
        assertEquals("314", appInfo.getString("buildNumber"))
        val deviceJson = start.getJSONObject("device")
        for (key in listOf("id", "platform", "screenDensity", "screenDpi", "screenPixelDensity")) {
            assertTrue("device.$key", deviceJson.has(key))
        }
        assertTrue(deviceJson.getJSONObject("screenSize").getDouble("width") > 0)
        assertTrue(deviceJson.getJSONObject("screenSize").getDouble("height") > 0)
        assertEquals("10.0.2.2", start.getJSONObject("ipInfo").getString("ip"))
        assertTrue(start.getJSONObject("locale").getString("language").isNotEmpty())

        val upload = awaitRequest { it.lane == "frames" }.body as HttpBody.Multipart
        val metadataField = upload.fields.first { it.first == "frameMetadata" }.second
        val entries = JSONArray(metadataField)
        assertTrue(entries.length() > 0)
        for (i in 0 until entries.length()) {
            assertEquals("nativeCpuExperimental", entries.getJSONObject(i).getString("requestedBackend"))
            assertEquals("nativeCpuExperimental", entries.getJSONObject(i).getString("resolvedBackend"))
        }

        host.post(SessionMessages.SESSION_END, SessionMessages.sessionEnd(), SystemHostClock.now())
        val end = awaitRequest { it.lane == "lifecycle" && "session_end" in it.json() }
        assertTrue(SessionEndWatcher.isSessionEnd(end))
    }

    /** Answers a capture as the coordinator would, with a stand-in JPEG. */
    private fun answer(requestId: String) {
        val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xD9.toByte())
        val handle = frames.put(jpeg)
        val reply = CaptureAnswer.Captured(
            requestId = requestId,
            frame = CapturedFrame(handle, 300, 600, "sha-$requestId", true, jpeg.size, 1000, "00ff00ff00ff00ff", "sig"),
            boundaryRect = BoundaryRect(0.0, 0.0, 400.0, 800.0),
            timings = CaptureTimingsMicros(readbackMicros = 500),
        )
        host.post(HostMessages.CAPTURE_RESULT, reply.toInputJson(), SystemHostClock.now(), reply.frameHandles)
    }

    private fun awaitRequest(match: (HttpRequest) -> Boolean): HttpRequest {
        val deadline = System.currentTimeMillis() + 20_000
        while (System.currentTimeMillis() < deadline) {
            http.requests.firstOrNull(match)?.let { return it }
            Thread.sleep(20)
        }
        throw AssertionError("no matching http.send; saw ${http.requests.map { it.lane + " " + it.path }}")
    }

    private fun HttpRequest.json(): String = (body as? HttpBody.Json)?.text.orEmpty()

    /** Records each request and accepts it, with a collector session id for lifecycle posts. */
    private class RecordingSender : HttpSender {
        val requests = CopyOnWriteArrayList<HttpRequest>()

        override fun send(request: HttpRequest, onResult: (TransportOutcome) -> Unit) {
            requests += request
            val body = if (request.lane == "lifecycle") """{"accepted":true,"sessionId":"collector-1"}""" else """{"accepted":true}"""
            onResult(TransportOutcome.Http(202, body))
        }
    }
}
