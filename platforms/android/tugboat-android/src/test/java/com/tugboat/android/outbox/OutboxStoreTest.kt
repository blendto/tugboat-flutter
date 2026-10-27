package com.tugboat.android.outbox

import com.tugboat.android.outbox.OutboxFixtures.entryDirs
import com.tugboat.android.outbox.OutboxFixtures.events
import com.tugboat.android.outbox.OutboxFixtures.frames
import com.tugboat.android.outbox.OutboxFixtures.inputs
import com.tugboat.android.outbox.OutboxFixtures.jpeg
import com.tugboat.android.outbox.OutboxFixtures.lifecycle
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeFalse
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

    private val sender = outbox.registerSender()

    private fun keep(vararg requests: com.tugboat.android.host.HttpRequest) {
        val frameBytes = mapOf("frame-1" to jpeg(1), "frame-2" to jpeg(2))
        requests.forEach { outbox.write(OutboxKeys.capture(it, frameBytes::get)!!, inputs, "0.1.0", sender) }
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

    private fun editEntry(key: String, edit: (JSONObject) -> Unit) {
        val file = dirOf(key).resolve("entry.json")
        file.writeText(JSONObject(file.readText()).also(edit).toString())
    }

    private fun eventKey(vararg ids: String) = OutboxKeys.capture(events("s-1", *ids)) { null }!!.single().key

    @Test
    fun numbersOutsideTheirRangeMakeAnEntryCorrupt() {
        keep(events("s-1", "a"), events("s-1", "b"), events("s-1", "c"))
        editEntry(eventKey("a")) { it.put("createdAtWallMs", Long.MIN_VALUE) }
        editEntry(eventKey("b")) { it.put("replays", 1L shl 60) }

        val scan = outbox.scanAndEvict()

        assertEquals(2, scan.corrupt)
        assertEquals(listOf(eventKey("c")), scan.entries.map { it.key })
    }

    @Test
    fun anEntryThatCannotBeReadIsSkippedAndKept() {
        keep(lifecycle())
        val entry = dirOf("s-1/l/session_start/2026-10-27T10:00:00.000Z").resolve("entry.json")
        entry.setReadable(false)
        assumeFalse("running as root: every file is readable", entry.canRead())
        try {
            val scan = outbox.scanAndEvict()
            assertEquals(0, scan.corrupt)
            assertTrue(scan.entries.isEmpty())
            assertEquals("kept", 1, entryDirs(root).size)
        } finally {
            entry.setReadable(true)
        }
        assertEquals(1, outbox.scanAndEvict().entries.size)
    }

    @Test
    fun aSaltThatCannotBeReadTurnsTheOutboxOffAndIsKept() {
        val salt = File(root, "install-salt").apply {
            parentFile?.mkdirs()
            writeBytes(ByteArray(32) { 7 })
            setReadable(false)
        }
        assumeFalse("running as root: every file is readable", salt.canRead())
        try {
            outbox.write(OutboxKeys.capture(lifecycle()) { null }!!, inputs, "0.1.0", sender)
            assertTrue(outbox.awaitQueued(5_000))
            assertEquals(1, outbox.writeFailures.get())
            assertTrue("no writes", entryDirs(root).isEmpty())
        } finally {
            salt.setReadable(true)
        }
        assertArrayEquals("never replaced", ByteArray(32) { 7 }, salt.readBytes())
    }

    @Test
    fun aCrashedWritersTempDirectoryIsCleanedAndOneBeingBuiltIsKept() {
        keep(lifecycle())
        val stale = File(root, "v1/.stale-entry").apply { mkdirs() }
        stale.setLastModified(now - OutboxStore.STALE_TEMP_MS - 1_000)
        val building = File(root, "v1/.building-entry").apply { mkdirs() }
        building.setLastModified(now)

        outbox.scanAndEvict()

        assertTrue(!stale.exists())
        assertTrue(building.exists())
    }

    @Test
    fun writesPastTheBoundsEvictWithoutWaitingForAScan() {
        outbox.settings = OutboxSettings(1L shl 30, maxEntries = 2, maxAgeMs = 1L shl 40, maxAttempts = 8)
        keep(events("s-1", "a"))
        keep(events("s-1", "b"))
        keep(events("s-1", "c"))

        assertEquals(2, entryDirs(root).size)
    }

    @Test
    fun aScanDeletesWhatTheBoundsEvict() {
        keep(events("s-1", "a"), events("s-1", "b"), events("s-1", "c"))
        outbox.settings = OutboxSettings(1L shl 30, maxEntries = 1, maxAgeMs = 1L shl 40, maxAttempts = 8)

        val scan = outbox.scanAndEvict()

        assertEquals(1, scan.entries.size)
        assertEquals(1, entryDirs(root).size)
    }

    @Test
    fun evictionTakesOtherSessionsFirstThenFramesBeforeEventsAndNeverLifecycleOrInFlight() {
        fun stored(key: String, lane: OutboxLane, session: String, created: Long) =
            StoredEntry("d-$key", key, lane, "/p", session, created, created, 1, 0, "epoch-a", "id", "0.1.0", 100)
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
            StoredEntry("d-$key", key, OutboxLane.FRAMES, "/p", "s-1", created, created, 1, 0, "epoch-b", "id", "0.1.0", 400)
        val settings = OutboxSettings(maxBytes = 1_000, maxEntries = 1000, maxAgeMs = 1L shl 40, maxAttempts = 8)

        val evicted = OutboxPolicy.evictions(listOf(stored("b", 2), stored("a", 1), stored("c", 3)), settings, { true }, { false })

        assertEquals(listOf("a"), evicted.map { it.key })
    }
}
