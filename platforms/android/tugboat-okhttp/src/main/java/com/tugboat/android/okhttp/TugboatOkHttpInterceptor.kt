package com.tugboat.android.okhttp

import com.tugboat.android.NetworkCall
import com.tugboat.android.NetworkFailure
import com.tugboat.android.Tugboat
import com.tugboat.android.adapter.TugboatAdapters
import okhttp3.Call
import okhttp3.Interceptor
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.io.InterruptedIOException

/**
 * Records each logical OkHttp call as `network_call` evidence, the OkHttp
 * counterpart of `tugboat_dio`'s `TugboatDioInterceptor`.
 *
 * Add it **first**, with `addInterceptor`, so it wraps every other
 * application interceptor (README "Install order"):
 *
 * ```kotlin
 * val client = OkHttpClient.Builder()
 *     .addInterceptor(TugboatOkHttpInterceptor { request -> routeOf(request) })  // first: outermost
 *     .addInterceptor(authInterceptor)
 *     .addInterceptor(retryInterceptor)
 *     .build()
 * ```
 *
 * OkHttp runs application interceptors in the order they were added, each
 * wrapping the ones after it, and runs its own retries, redirects, and
 * follow-ups below all of them. Outermost, this interceptor sees one
 * request and one final response (or failure) per call, after the app's
 * auth and retry interceptors have finished: that is what "install after
 * auth and retry interceptors" means for Dio, whose retry handlers must run
 * before its adapter finishes the call. Installed as a network interceptor
 * it records nothing (it would see every redirect and retry hop).
 *
 * [routeResolver] maps the request to a bounded route path that you choose,
 * such as `/orders/{id}` or `/orders/123`: never a URL, query, or fragment.
 * Its result is trimmed (as Dart's `String.trim`); null, blank, or a throw
 * records nothing. It runs once per call on the calling thread, and only
 * while Tugboat takes evidence.
 *
 * The status code is recorded for every response. For status 400 or more, a
 * bounded copy of the error body (at most 64 KiB peeked, never consumed) is
 * recorded too. An `IOException` is `NETWORK_ERROR` (timeouts included), and
 * a cancelled call is `CANCELLED`; the exception is rethrown unchanged.
 * `attemptCount` is not recorded: retries below this interceptor are not
 * observable to it.
 *
 * Never read: URLs (except through [routeResolver]), query strings, headers
 * (except `Content-Type`, to classify an error body), request bodies,
 * success response bodies, and exception messages. The request and response
 * are passed on unchanged, and nothing Tugboat does throws into the call.
 */
class TugboatOkHttpInterceptor(private val routeResolver: (Request) -> String?) : Interceptor {
    @Throws(IOException::class)
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val begun = begin(chain, request) ?: return chain.proceed(request)
        val response = try {
            ActiveCalls.within(begun.okhttpCall) { chain.proceed(request) }
        } catch (failure: IOException) {
            fail(begun, failure)
            throw failure
        }
        complete(begun, response)
        return response
    }

    /** The recorded call, or null when this call is not recorded here. Never throws. */
    private fun begin(chain: Interceptor.Chain, request: Request): Begun? = try {
        val okhttpCall = chain.call()
        when {
            // Only network interceptors have a connection: they see every hop.
            chain.connection() != null -> null
            // An outer TugboatOkHttpInterceptor records this call already.
            ActiveCalls.isActive(okhttpCall) -> null
            !TugboatAdapters.isAcceptingEvidence -> null
            else -> resolveRoute(request)?.let { route ->
                Begun(Tugboat.beginNetworkCall(request.method(), route), okhttpCall, System.nanoTime())
            }
        }
    } catch (_: Throwable) {
        null
    }

    private fun resolveRoute(request: Request): String? {
        val route = try {
            routeResolver(request)
        } catch (_: Throwable) {
            return null
        }
        return route?.let(::dartTrim)?.takeIf { it.isNotEmpty() }
    }

    private fun complete(begun: Begun, response: Response) {
        try {
            val status = response.code()
            val body = if (status >= ERROR_STATUS) readErrorBody(response) else null
            begun.call.complete(statusCode = status, errorResponseBody = body)
        } catch (_: Throwable) {
            // Observation never affects the call.
        }
    }

    private fun readErrorBody(response: Response) = try {
        ErrorBodies.read(response)
    } catch (_: Throwable) {
        null
    }

    private fun fail(begun: Begun, failure: IOException) {
        try {
            val outcome = if (isCancellation(begun, failure)) NetworkFailure.CANCELLED else NetworkFailure.NETWORK_ERROR
            begun.call.fail(outcome)
        } catch (_: Throwable) {
            // Observation never affects the call.
        }
    }

    /**
     * A cancelled call, but not a timeout. OkHttp cancels the call when its
     * call timeout fires, so a call that failed at or after that deadline is
     * a timeout, as is an `InterruptedIOException` (connect, read, write,
     * and call timeouts).
     */
    private fun isCancellation(begun: Begun, failure: IOException): Boolean {
        if (failure is InterruptedIOException) return false
        if (!begun.okhttpCall.isCanceled() && failure.message != CANCELED_MESSAGE) return false
        val callTimeoutNanos = begun.okhttpCall.timeout().timeoutNanos()
        val elapsed = System.nanoTime() - begun.startNanos
        return callTimeoutNanos <= 0 || elapsed < callTimeoutNanos - CALL_TIMEOUT_SLACK_NANOS
    }

    private class Begun(val call: NetworkCall, val okhttpCall: Call, val startNanos: Long)

    private companion object {
        const val ERROR_STATUS = 400

        /** The message of the `IOException` OkHttp throws for a cancelled call. */
        const val CANCELED_MESSAGE = "Canceled"

        /** The call timeout starts just before the interceptors run. */
        const val CALL_TIMEOUT_SLACK_NANOS = 20_000_000L
    }
}

/**
 * The calls a [TugboatOkHttpInterceptor] is recording on this thread, so a
 * second instance in the same chain (added twice, or a client built from one
 * that has it) records nothing. A chain runs on one thread; a nested call
 * made by an interceptor is a different call and is recorded on its own.
 */
private object ActiveCalls {
    private val current = ThreadLocal<Call?>()

    fun isActive(call: Call) = current.get() === call

    inline fun <T> within(call: Call, block: () -> T): T {
        val previous = current.get()
        current.set(call)
        try {
            return block()
        } finally {
            if (previous == null) current.remove() else current.set(previous)
        }
    }
}

/** Dart's `String.trim`: its whitespace code units, from both ends (the engine's `dart_trim`). */
internal fun dartTrim(value: String): String = value.trim(::isDartWhitespace)

private fun isDartWhitespace(c: Char): Boolean = when (c.code) {
    in 0x09..0x0D, 0x20, 0x85, 0xA0, 0x1680, in 0x2000..0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF -> true
    else -> false
}
