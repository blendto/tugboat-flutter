package com.tugboat.android.sdk

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Pins the installation id rules Flutter's `TugboatInstallationIdStore` has
 * (BLE-618): mint once, persist in `tugboat/installation_id`, read back,
 * replace a corrupt file, never throw, host id wins.
 */
class InstallationIdTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val uuidPattern = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")

    private fun idFile() = File(folder.root, "tugboat/installation_id")

    private fun store(mint: () -> String = { java.util.UUID.randomUUID().toString() }) =
        InstallationIdStore(directory = { folder.root }, mint = mint)

    @Test
    fun firstLaunchMintsAUuidV4AndPersistsIt() {
        val id = store().read()
        assertTrue(id, uuidPattern.matches(id))
        assertEquals(id, idFile().readText())
    }

    @Test
    fun laterLaunchReadsItBack() {
        val first = store().read()
        assertEquals(first, store(mint = { "other" }).read())
    }

    @Test
    fun oneIdPerProcess() {
        val store = store()
        assertEquals(store.read(), store.read())
    }

    @Test
    fun anotherInstallGetsAnotherId() {
        val first = store().read()
        folder.root.deleteRecursively()
        folder.root.mkdirs()
        assertNotEquals(first, store().read())
    }

    @Test
    fun corruptFilesAreReplaced() {
        for (bad in listOf("", "   \n", "x".repeat(129))) {
            idFile().parentFile!!.mkdirs()
            idFile().writeText(bad)
            val id = store(mint = { "fresh-id" }).read()
            assertEquals("fresh-id", id)
            assertEquals("fresh-id", idFile().readText())
        }
    }

    @Test
    fun surroundingWhitespaceIsTrimmedOnRead() {
        idFile().parentFile!!.mkdirs()
        idFile().writeText("  abc-123\n")
        assertEquals("abc-123", store().read())
    }

    @Test
    fun writeFailureStillReturnsAStableIdAndRetriesLater() {
        // A non-empty directory where the file should be makes the write fail.
        idFile().mkdirs()
        File(idFile(), "child").writeText("x")
        val store = store(mint = { "stable-id" })
        assertEquals("stable-id", store.read())
        assertEquals("stable-id", store.read())
        idFile().deleteRecursively()
        assertEquals("stable-id", store.read())
        assertEquals("stable-id", idFile().readText())
    }

    @Test
    fun unavailableDirectoryStillReturnsAnId() {
        val store = InstallationIdStore(directory = { null }, mint = { "mem-id" })
        assertEquals("mem-id", store.read())
        assertEquals("mem-id", store.read())
    }

    @Test
    fun hostIdWinsWhenNonBlank() {
        assertEquals("host-1", InstallationIdStore.resolve("  host-1 ") { error("not read") })
        assertEquals("sdk", InstallationIdStore.resolve("   ") { "sdk" })
        assertEquals("sdk", InstallationIdStore.resolve(null) { "sdk" })
    }

    @Test
    fun idSeedIs64LowercaseHexAndDiffersEachTime() {
        val a = IdSeed.generate()
        assertTrue(Regex("^[0-9a-f]{64}$").matches(a))
        assertNotEquals(a, IdSeed.generate())
    }

    @Test
    fun racingStoresAdoptTheIdThatReachedDisk() {
        val results = java.util.concurrent.ConcurrentLinkedQueue<String>()
        val start = java.util.concurrent.CountDownLatch(1)
        val threads = (1..6).map { n ->
            Thread {
                start.await()
                results += store(mint = { "racer-$n" }).read()
            }.also { it.start() }
        }
        start.countDown()
        threads.forEach { it.join() }
        assertEquals(1, results.toSet().size)
        assertEquals(results.first(), idFile().readText())
    }

    @Test
    fun theWrittenFileHoldsExactlyTheId() {
        val id = store(mint = { "exact-id" }).read()
        assertEquals(id, idFile().readText(Charsets.UTF_8))
        assertEquals(id.length.toLong(), idFile().length())
    }

    @Test
    fun theSessionIdIsTheEnginesForTheSeed() {
        // core/session-engine: seed 0x11 * 32 -> stream index 0 (tb_session_engine_stateful_test).
        assertEquals(
            "session-f81644b2-12d3-462e-b98c-29d15b723874",
            IdSeed.sessionId("11".repeat(32)),
        )
        assertEquals(
            "session-a9d6e500-293a-48bd-b8cb-e213d07ab71f",
            IdSeed.sessionId("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
        )
    }
}
