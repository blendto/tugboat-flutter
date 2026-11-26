package com.tugboat.capture

import android.os.Looper
import org.junit.rules.TestRule
import org.junit.rules.Timeout
import org.junit.runner.Description
import org.junit.runners.model.Statement
import org.junit.runners.model.TestTimedOutException

/**
 * Fails a test that runs longer than [seconds] instead of hanging the device
 * run, and reports where the main thread is, since a blocked main thread is
 * what stalls `ActivityScenario.onActivity`.
 */
class MainThreadTimeout(
    private val seconds: Long,
) : TestRule {
    override fun apply(
        base: Statement,
        description: Description,
    ): Statement =
        object : Statement() {
            override fun evaluate() {
                try {
                    Timeout.seconds(seconds).apply(base, description).evaluate()
                } catch (timeout: TestTimedOutException) {
                    val main = Looper.getMainLooper().thread
                    val frames = main.stackTrace.joinToString("\n  at ")
                    throw AssertionError("Timed out; main thread ${main.state}:\n  at $frames", timeout)
                }
            }
        }
}
