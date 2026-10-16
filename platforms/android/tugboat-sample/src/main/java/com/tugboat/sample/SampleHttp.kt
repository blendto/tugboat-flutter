package com.tugboat.sample

import android.util.Log
import com.tugboat.android.okhttp.TugboatOkHttpInterceptor
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException

/**
 * The sample's HTTP client. [TugboatOkHttpInterceptor] is added first, so it
 * wraps the app's own interceptors (here a stand-in auth header) and records
 * one `network_call` per logical call.
 */
internal object SampleHttp {
    private const val TAG = "TugboatSample"

    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .addInterceptor(TugboatOkHttpInterceptor(::route)) // first: outermost
            .addInterceptor(Interceptor { chain ->
                chain.proceed(chain.request().newBuilder().header("Authorization", "Bearer sample-token").build())
            })
            .build()
    }

    /** `/sample/orders/{id}` for an order request; anything else is not recorded. */
    private fun route(request: Request): String? {
        val segments = request.url.pathSegments
        return if (segments.size == 3 && segments[0] == "sample" && segments[1] == "orders") "/sample/orders/{id}" else null
    }

    /**
     * One real request, `GET <collector>/sample/orders/42?ref=sample`. The
     * collector has no such path: it answers 404, which Tugboat records with
     * its bounded error body. The query and the header are never recorded.
     */
    fun loadOrder() {
        val url = "${BuildConfig.COLLECTOR_URL.trimEnd('/')}/sample/orders/42?ref=sample"
        val request = runCatching { Request.Builder().url(url).build() }.getOrElse {
            Log.w(TAG, "not an HTTP URL: $url")
            return
        }
        client.newCall(request).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                Log.i(TAG, "order request failed: ${e.javaClass.simpleName}")
            }

            override fun onResponse(call: Call, response: Response) {
                response.use { Log.i(TAG, "order request answered ${it.code}, ${it.body?.string()?.length ?: 0} chars") }
            }
        })
    }
}
