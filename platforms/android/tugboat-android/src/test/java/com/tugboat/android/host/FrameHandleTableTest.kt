package com.tugboat.android.host

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.Callable
import java.util.concurrent.Executors

class FrameHandleTableTest {
    @Test
    fun putGetReleaseLifecycle() {
        val table = FrameHandleTable()
        val jpeg = byteArrayOf(1, 2, 3)
        val handle = table.put(jpeg)

        assertArrayEquals(jpeg, table[handle])
        assertEquals(1, table.size)
        assertTrue(table.release(handle))
        assertNull(table[handle])
        assertFalse("a second release is a no-op", table.release(handle))
        assertEquals(0, table.size)
    }

    @Test
    fun handlesAreNeverReused() {
        val table = FrameHandleTable()
        val first = table.put(byteArrayOf(1))
        table.release(first)
        val second = table.put(byteArrayOf(2))
        assertTrue(first != second)
        assertNull(table[first])
    }

    @Test
    fun unknownHandlesResolveToNull() {
        val table = FrameHandleTable()
        assertNull(table["frame-404"])
        assertFalse(table.release("frame-404"))
    }

    @Test
    fun closeFreesEverythingAndKeepsNothingAfterwards() {
        val table = FrameHandleTable()
        val handles = (1..3).map { table.put(byteArrayOf(it.toByte())) }
        table.close()
        assertEquals(0, table.size)
        handles.forEach { assertNull(table[it]) }

        val late = table.put(byteArrayOf(9))
        assertNull(table[late])
        assertEquals(0, table.size)
    }

    @Test
    fun putsRacingCloseRetainNothing() {
        val table = FrameHandleTable()
        val pool = Executors.newFixedThreadPool(4)
        try {
            val puts = (1..400).map { pool.submit(Callable { table.put(byteArrayOf(0)) }) }
            table.close()
            puts.forEach { it.get() }
            assertEquals(0, table.size)
        } finally {
            pool.shutdownNow()
        }
    }

    @Test
    fun concurrentPutsGetDistinctHandles() {
        val table = FrameHandleTable()
        val pool = Executors.newFixedThreadPool(4)
        try {
            val handles = pool.invokeAll((1..400).map { Callable { table.put(byteArrayOf(0)) } }).map { it.get() }
            assertEquals(400, handles.toSet().size)
            assertEquals(400, table.size)
        } finally {
            pool.shutdownNow()
        }
    }
}
