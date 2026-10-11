package com.tugboat.android.host

import com.tugboat.android.BuildConfig
import com.tugboat.android.host.LocalHttpServer.Response
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ServerSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** [HttpExecutor] against a real local HTTP server. */
class HttpExecutorTest {
    private val server = LocalHttpServer().apply { reply = { Response(202, "{\"sessionId\":\"s-1\"}") } }
    private val received = server.received
    private val frames = FrameHandleTable()
    private val executor = HttpExecutor(config("http://127.0.0.1:${server.port}/"), frames)

    @After
    fun tearDown() {
        executor.close()
        server.close()
    }

    @Test
    fun jsonRequestCarriesTheFlutterHeadersAndTheExactBody() {
        val body = """{"events":[{"w":390.0}]}"""
        val outcome = executor.perform(json(body, path = "/v1/events/batch"))

        assertEquals(TransportOutcome.Http(202, "{\"sessionId\":\"s-1\"}"), outcome)
        val request = received.single()
        assertEquals("POST", request.method)
        assertEquals("/v1/events/batch", request.path)
        assertEquals(body, request.body.toString(Charsets.UTF_8))
        val expected = mapOf(
            "x-pmkit-api-key" to "pmk_key",
            "x-tugboat-api-key" to "pmk_key",
            "x-platform" to "android",
            "x-app-build" to "42",
            "x-app-version" to "1.2.3",
            "x-app-id" to "com.example.app",
            "x-sdk-version" to BuildConfig.SDK_VERSION,
            "content-type" to "application/json; charset=utf-8",
        )
        expected.forEach { (name, value) -> assertEquals(name, value, request.headers[name]) }
    }

    @Test
    fun collectorHeadersKeepTheFlutterNamesAndOrder() {
        assertEquals(
            listOf(
                "X-PMKit-API-Key", "X-Tugboat-API-Key", "X-Platform", "X-App-Build",
                "X-App-Version", "X-App-Id", "X-Sdk-Version",
            ),
            config("http://x").collectorHeaders().keys.toList(),
        )
        assertTrue("toString never prints the key", "pmk_key" !in config("http://x").toString())
    }

    @Test
    fun statusAndBodyPassThroughForRejections() {
        server.reply = { Response(400, "{\"error\":\"bad\"}") }
        assertEquals(TransportOutcome.Http(400, "{\"error\":\"bad\"}"), executor.perform(json("{}")))
    }

    @Test
    fun redirectsAreReportedNotFollowed() {
        server.reply = { Response(302, headers = mapOf("Location" to "/elsewhere")) }
        assertEquals(TransportOutcome.Http(302, ""), executor.perform(json("{}")))
        assertEquals(1, received.size)
    }

    @Test
    fun bodiesAreTruncatedTo64KiB() {
        server.reply = { Response(202, "x".repeat(100 * 1024)) }
        val outcome = executor.perform(json("{}")) as TransportOutcome.Http
        assertEquals(HttpExecutor.MAX_BODY_BYTES, outcome.body.length)
    }

    @Test
    fun multipartMatchesTheFlutterFrameUpload() {
        val first = byteArrayOf(-1, -40, 1, 2)
        val second = byteArrayOf(-1, -40, 3)
        val request = HttpRequest(
            requestIdJson = "\"r\"",
            lane = "frames",
            path = "/v1/frames",
            timeoutMs = 15_000,
            body = HttpBody.Multipart(
                fields = listOf("sessionId" to "s-1", "frameNos" to "1,2", "frameMetadata" to "[{\"frameNo\":1},{\"frameNo\":2}]"),
                frames = listOf(FramePart(frames.put(first), "1.jpg"), FramePart(frames.put(second), "2.jpg")),
            ),
        )

        assertEquals(TransportOutcome.Http(202, "{\"sessionId\":\"s-1\"}"), executor.perform(request))
        val upload = received.single()
        val contentType = upload.headers.getValue("content-type")
        assertTrue(contentType, contentType.startsWith("multipart/form-data; boundary="))
        val parts = MultipartParts.parse(upload.body, contentType.substringAfter("boundary="))

        assertEquals(listOf("sessionId", "frameNos", "frameMetadata", "files", "files"), parts.map { it.name })
        assertEquals(listOf(null, null, null, "1.jpg", "2.jpg"), parts.map { it.filename })
        assertEquals("s-1", parts[0].text)
        assertEquals("1,2", parts[1].text)
        assertEquals("[{\"frameNo\":1},{\"frameNo\":2}]", parts[2].text)
        assertEquals("image/jpeg", parts[3].contentType)
        assertArrayEquals(first, parts[3].bytes)
        assertArrayEquals(second, parts[4].bytes)
    }

    @Test
    fun aReleasedFrameFailsTheRequestWithoutSendingIt() {
        val handle = frames.put(byteArrayOf(1))
        frames.release(handle)
        val request = HttpRequest(
            "\"r\"", "frames", "/v1/frames", 1000,
            HttpBody.Multipart(listOf("sessionId" to "s"), listOf(FramePart(handle, "1.jpg"))),
        )

        assertEquals(TransportOutcome.Error, executor.perform(request))
        assertEquals(0, received.size)
    }

    @Test
    fun slowResponsesTimeOut() {
        val release = CountDownLatch(1)
        server.reply = {
            release.await(5, TimeUnit.SECONDS)
            Response(202)
        }
        try {
            assertEquals(TransportOutcome.Timeout, executor.perform(json("{}", timeoutMs = 200)))
        } finally {
            release.countDown()
        }
    }

    @Test
    fun connectionFailuresAreErrors() {
        val closedPort = ServerSocket(0).use { it.localPort }
        val offline = HttpExecutor(config("http://127.0.0.1:$closedPort"), frames)
        try {
            assertEquals(TransportOutcome.Error, offline.perform(json("{}")))
        } finally {
            offline.close()
        }
    }

    @Test
    fun malformedBaseUrlsAreErrors() {
        val broken = HttpExecutor(config("not a url"), frames)
        try {
            assertEquals(TransportOutcome.Error, broken.perform(json("{}")))
        } finally {
            broken.close()
        }
    }

    @Test
    fun sendAnswersAsynchronouslyOnTheIoThread() {
        val outcome = AtomicReference<TransportOutcome>()
        val thread = AtomicReference<String>()
        val done = CountDownLatch(1)
        executor.send(json("{}")) {
            outcome.set(it)
            thread.set(Thread.currentThread().name)
            done.countDown()
        }

        assertTrue(done.await(5, TimeUnit.SECONDS))
        assertEquals(TransportOutcome.Http(202, "{\"sessionId\":\"s-1\"}"), outcome.get())
        assertEquals("tugboat-io", thread.get())
    }

    @Test
    fun sendAfterCloseAnswersError() {
        executor.close()
        val outcome = AtomicReference<TransportOutcome>()
        executor.send(json("{}")) { outcome.set(it) }
        assertEquals(TransportOutcome.Error, outcome.get())
    }

    private fun json(body: String, path: String = "/v1/sessions", timeoutMs: Int = 5_000) =
        HttpRequest("\"r\"", "lifecycle", path, timeoutMs, HttpBody.Json(body))

    private fun config(baseUrl: String) = HostConfig(
        collectorBaseUrl = baseUrl,
        apiKey = "pmk_key",
        appVersion = "1.2.3",
        appBuild = "42",
        appId = "com.example.app",
    )
}
