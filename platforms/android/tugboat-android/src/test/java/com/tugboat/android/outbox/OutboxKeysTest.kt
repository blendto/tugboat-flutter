package com.tugboat.android.outbox

import com.tugboat.android.outbox.OutboxFixtures.events
import com.tugboat.android.outbox.OutboxFixtures.frames
import com.tugboat.android.outbox.OutboxFixtures.jpeg
import com.tugboat.android.outbox.OutboxFixtures.lifecycle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Keys derived from the bodies the engine sends (W11 design 3.1), and the replay backoff. */
@RunWith(RobolectricTestRunner::class)
class OutboxKeysTest {
    private fun keys(request: com.tugboat.android.host.HttpRequest) =
        OutboxKeys.capture(request) { handle -> jpeg(handle.removePrefix("frame-").toInt()) }?.map { it.key }

    @Test
    fun eachLaneKeysItsLogicalUnit() {
        assertEquals(listOf("s-1/l/session_end/2026-10-27T10:00:01.000Z"), keys(lifecycle(eventType = "session_end", triggeredAt = "2026-10-27T10:00:01.000Z")))
        assertEquals(listOf("s-1/f/3", "s-1/f/4"), keys(frames("s-1", 3, 4)))
        val batch = keys(events("s-1", "e-1", "e-2"))!!.single()
        assertEquals("s-1/e/" + OutboxKeys.sha256Hex("e-1\ne-2").take(16), batch)
    }

    @Test
    fun anEventBatchKeyIgnoresOrderButNotMembership() {
        assertEquals(keys(events("s-1", "e-1", "e-2")), keys(events("s-1", "e-2", "e-1")))
        assertNotEquals(keys(events("s-1", "e-1", "e-2")), keys(events("s-1", "e-1", "e-3")))
    }

    @Test
    fun aBodyWithoutItsKeyFieldsHasNoKey() {
        assertNull(keys(lifecycle().copy(body = com.tugboat.android.host.HttpBody.Json("""{"sessionId":"s-1","eventType":"x"}"""))))
        assertNull(keys(events().copy(body = com.tugboat.android.host.HttpBody.Json("""{"events":[{"sessionId":"s-1"}]}"""))))
        assertNull("a frame whose bytes are gone", OutboxKeys.capture(frames("s-1", 1)) { null })
        assertNull(keys(lifecycle().copy(lane = "unknown")))
    }

    @Test
    fun backoffDoublesToItsCapAndRetryAfterOnlyLengthensIt() {
        assertEquals(2_000L, OutboxBackoff.delayMs(1, null, 0))
        assertEquals(4_000L, OutboxBackoff.delayMs(2, null, 0))
        assertEquals(OutboxBackoff.CAP_MS, OutboxBackoff.delayMs(30, null, 0))
        assertEquals(120_000L, OutboxBackoff.delayMs(1, " 120 ", 0))
        assertEquals("a shorter Retry-After keeps the curve", 4_000L, OutboxBackoff.delayMs(2, "1", 0))
        val now = 1_793_095_200_000L // 2026-10-27T10:00:00Z
        assertEquals(30_000L, OutboxBackoff.delayMs(1, "Tue, 27 Oct 2026 10:00:30 GMT", now))
        assertEquals("unparseable is ignored", 2_000L, OutboxBackoff.delayMs(1, "soon", 0))
    }
}
