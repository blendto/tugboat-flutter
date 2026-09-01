package com.tugboat.capture.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class PixelCopyRecycleGuardTest {
    @Test
    fun successfulCopyDoesNotRecycleInCallback() {
        val recycled = AtomicInteger(0)
        val guard = PixelCopyRecycleGuard { recycled.incrementAndGet() }
        guard.onCallback()
        assertEquals(0, recycled.get())
    }

    @Test
    fun timeoutThenCallbackRecyclesOnce() {
        val recycled = AtomicInteger(0)
        val guard = PixelCopyRecycleGuard { recycled.incrementAndGet() }
        assertFalse(guard.callerOwnsAfterTimeout())
        guard.onCallback()
        assertEquals(1, recycled.get())
        guard.onCallback()
        assertEquals(1, recycled.get())
    }

    @Test
    fun callbackThenTimeoutLeavesCallerOwning() {
        val recycled = AtomicInteger(0)
        val guard = PixelCopyRecycleGuard { recycled.incrementAndGet() }
        guard.onCallback()
        assertTrue(guard.callerOwnsAfterTimeout())
        assertEquals(0, recycled.get())
    }

    @Test
    fun concurrentTimeoutAndCallbackRecyclesAtMostOnce() {
        val recycled = AtomicInteger(0)
        val guard = PixelCopyRecycleGuard { recycled.incrementAndGet() }
        val callerOwns = AtomicBoolean(false)
        val barrier = CyclicBarrier(2)
        val done = CountDownLatch(2)
        val pool = Executors.newFixedThreadPool(2)
        try {
            pool.execute {
                barrier.await()
                if (guard.callerOwnsAfterTimeout()) callerOwns.set(true)
                done.countDown()
            }
            pool.execute {
                barrier.await()
                guard.onCallback()
                done.countDown()
            }
            assertTrue(done.await(5, TimeUnit.SECONDS))
        } finally {
            pool.shutdownNow()
        }
        val recycledCount = recycled.get()
        if (callerOwns.get()) {
            assertEquals(0, recycledCount)
        } else {
            assertEquals(1, recycledCount)
        }
    }
}
