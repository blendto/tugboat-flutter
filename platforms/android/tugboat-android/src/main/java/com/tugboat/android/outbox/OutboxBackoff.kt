package com.tugboat.android.outbox

import com.tugboat.android.host.CollectorResponse
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/**
 * The drainer's wait after a retried answer: exponential from [BASE_MS],
 * doubling per attempt up to [CAP_MS], or the collector's `Retry-After` when
 * that is longer (at most [RETRY_AFTER_CAP_MS]).
 */
internal object OutboxBackoff {
    const val BASE_MS = 2_000L
    const val CAP_MS = 5L * 60 * 1000
    const val RETRY_AFTER_CAP_MS = 60L * 60 * 1000

    /** [attempts]: sends of the entry so far, at least 1. */
    fun delayMs(attempts: Int, retryAfter: String?, nowWallMs: Long): Long {
        val shift = (attempts - 1).coerceIn(0, 30)
        val curve = (BASE_MS shl shift).coerceAtMost(CAP_MS)
        val asked = retryAfter?.let { retryAfterMs(it, nowWallMs) } ?: 0L
        return maxOf(curve, asked)
    }

    /**
     * `Retry-After` as RFC 9110 has it (delta-seconds or an HTTP-date), as
     * the engine reads the value the host forwards
     * ([CollectorResponse.forwardRetryAfter]); null when unparseable.
     */
    fun retryAfterMs(raw: String, nowWallMs: Long): Long? {
        val value = CollectorResponse.forwardRetryAfter(raw) ?: return null
        if (value.all { it in '0'..'9' }) {
            val seconds = value.toBigInteger()
            val capped = seconds.min((RETRY_AFTER_CAP_MS / 1000).toBigInteger()).toLong()
            return capped * 1000
        }
        return try {
            val format = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("GMT")
                isLenient = false
            }
            val at = format.parse(value)?.time ?: return null
            (at - nowWallMs).coerceIn(0, RETRY_AFTER_CAP_MS)
        } catch (_: Throwable) {
            null
        }
    }
}
