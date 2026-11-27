package com.tugboat.android.outbox

import com.tugboat.android.host.FramePart
import com.tugboat.android.host.HostConfig
import com.tugboat.android.host.HttpBody
import com.tugboat.android.host.HttpRequest
import org.junit.Assert.assertTrue
import java.io.File
import java.nio.file.Files

/** Requests shaped as the engine sends them, and outboxes over a temp directory. */
internal object OutboxFixtures {
    val inputs = OutboxIdentityInputs("http://127.0.0.1:1", "com.example.app", "pmk_key")

    fun tempRoot(): File = Files.createTempDirectory("outbox").toFile()

    /** One process's outbox over [root]; tests make two over one directory for a restart. */
    fun outbox(root: File, epoch: String, wallMs: () -> Long = System::currentTimeMillis) =
        Outbox(root = { root }, processEpoch = epoch, wallMs = wallMs)

    fun lifecycle(
        sessionId: String = "s-1",
        eventType: String = "session_start",
        triggeredAt: String = "2026-10-27T10:00:00.000Z",
        userId: String = "u-1",
    ) = HttpRequest(
        "http-1", "lifecycle", "/v1/sessions", 15_000,
        HttpBody.Json(
            """{"sessionId":"$sessionId","eventType":"$eventType","atMs":0,"triggeredAt":"$triggeredAt","userId":"$userId"}""",
        ),
    )

    fun events(sessionId: String = "s-1", vararg ids: String = arrayOf("e-1", "e-2")) = HttpRequest(
        "http-2", "events", "/v1/events/batch", 15_000,
        HttpBody.Json(
            ids.joinToString(",", prefix = """{"events":[""", postfix = "]}") { """{"id":"$it","sessionId":"$sessionId"}""" },
        ),
    )

    /** A chunk of frames [numbers]; handle `frame-<n>`. */
    fun frames(sessionId: String = "s-1", vararg numbers: Int) = HttpRequest(
        "http-3", "frames", "/v1/frames", 15_000,
        HttpBody.Multipart(
            listOf(
                "sessionId" to sessionId,
                "frameNos" to numbers.joinToString(","),
                "frameMetadata" to numbers.joinToString(",", "[", "]") { """{"atMs":$it}""" },
            ),
            numbers.map { FramePart("frame-$it", "$it.jpg") },
        ),
    )

    fun jpeg(n: Int) = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), n.toByte())

    fun hostConfig(baseUrl: String) = HostConfig(baseUrl, "pmk_key", "1.2.3", "42", "com.example.app")

    fun entryDirs(root: File): List<File> =
        File(root, "v1").listFiles()?.filter { !it.name.startsWith(".") }.orEmpty()

    fun awaitUntil(timeoutMs: Long = 5_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (!condition() && System.currentTimeMillis() < deadline) Thread.sleep(10)
        assertTrue("timed out", condition())
    }
}
