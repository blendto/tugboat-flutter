package com.tugboat.android.outbox

import com.tugboat.android.outbox.OutboxFixtures.entryDirs
import com.tugboat.android.outbox.OutboxFixtures.events
import com.tugboat.android.outbox.OutboxFixtures.frames
import com.tugboat.android.outbox.OutboxFixtures.inputs
import com.tugboat.android.outbox.OutboxFixtures.jpeg
import com.tugboat.android.outbox.OutboxFixtures.lifecycle
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/** Scans and bounds (W11 design 3.4): corrupt, unknown-version, and expired entries go; eviction order. */
@RunWith(RobolectricTestRunner::class)
class OutboxStoreTest {
    private val root = OutboxFixtures.tempRoot()
    private var now = 1_000_000L
    private val outbox = OutboxFixtures.outbox(root, "epoch-a") { now }

    @After
    fun tearDown() {
        root.deleteRecursively()
    }

    private fun keep(vararg requests: com.tugboat.android.host.HttpRequest) {
        val frameBytes = mapOf("frame-1" to jpeg(1), "frame-2" to jpeg(2))
        requests.forEach { outbox.write(OutboxKeys.capture(it, frameBytes::get)!!, inputs, "0.1.0") }
        assertTrue(outbox.awaitQueued(5_000))
    }

    private fun dirOf(key: String) = File(File(root, "v1"), outbox.dirName(key))

    @Test
    fun corruptAndUnknownVersionEntriesAreDeletedAndCounted() {
        keep(lifecycle(), events(), frames("s-1", 1))
        dirOf("s-1/l/session_start/2026-10-27T10:00:00.000Z").resolve("entry.json").writeText("{not json")
        val events = dirOf(OutboxKeys.capture(events()) { null }!!.single().key).resolve("entry.json")
        events.writeText(JSONObject(events.readText()).put("v", 2).toString())

        val scan = outbox.scanAndEvict()

        assertEquals(2, scan.corrupt)
        assertEquals(listOf("s-1/f/1"), scan.entries.map { it.key })
        assertEquals(1, entryDirs(root).size)
    }

    @Test
    fun entriesPastTheMaxAgeAreDeletedAsExpired() {
        outbox.settings = OutboxSettings(1L shl 30, 1000, maxAgeMs = 10_000, maxAttempts = 8)
        keep(lifecycle())
        now += 5_000
        keep(events())
        now += 6_000

        val scan = outbox.scanAndEvict()

        assertEquals(1, scan.expired)
        assertEquals(1, scan.entries.size)
        assertEquals(1, entryDirs(root).size)
    }

    @Test
    fun evictionTakesOtherSessionsFirstThenFramesBeforeEventsAndNeverLifecycleOrInFlight() {
        fun stored(key: String, lane: OutboxLane, session: String, created: Long) =
            StoredEntry("d-$key", key, lane, "/p", session, created, created, 1, "epoch-a", "id", "0.1.0", 100)
        val entries = listOf(
            stored("current-frame", OutboxLane.FRAMES, "s-2", 1),
            stored("old-events", OutboxLane.EVENTS, "s-1", 2),
            stored("old-frame", OutboxLane.FRAMES, "s-1", 3),
            stored("old-lifecycle", OutboxLane.LIFECYCLE, "s-1", 0),
            stored("old-frame-in-flight", OutboxLane.FRAMES, "s-1", 0),
            stored("current-events", OutboxLane.EVENTS, "s-2", 0),
        )
        val settings = OutboxSettings(maxBytes = 1L shl 30, maxEntries = 2, maxAgeMs = 1L shl 40, maxAttempts = 8)

        val evicted = OutboxPolicy.evictions(
            entries,
            settings,
            isOrphan = { it.sessionId == "s-1" },
            isActive = { it == "old-frame-in-flight" },
        )

        assertEquals(listOf("old-frame", "old-events", "current-frame", "current-events"), evicted.map { it.key })
    }

    @Test
    fun theByteBoundEvictsUntilTheOutboxFits() {
        fun stored(key: String, created: Long) =
            StoredEntry("d-$key", key, OutboxLane.FRAMES, "/p", "s-1", created, created, 1, "epoch-b", "id", "0.1.0", 400)
        val settings = OutboxSettings(maxBytes = 1_000, maxEntries = 1000, maxAgeMs = 1L shl 40, maxAttempts = 8)

        val evicted = OutboxPolicy.evictions(listOf(stored("b", 2), stored("a", 1), stored("c", 3)), settings, { true }, { false })

        assertEquals(listOf("a"), evicted.map { it.key })
    }
}
