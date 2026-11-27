package com.tugboat.reactnative

import com.facebook.react.modules.network.NetworkingModule
import com.tugboat.android.okhttp.TugboatOkHttpInterceptor
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * Records `fetch` and `XMLHttpRequest` calls: both go through React Native's OkHttp
 * client. The route is the URL path, never the URL or query. There is one slot for a
 * custom client builder, so this replaces an app's own.
 */
internal object TugboatNetwork {
    // Only what this object installed is ever removed: an app's own builder stays.
    private var installed = false

    /** Removes the interceptor, if this object installed it (`captureNetwork: false`). */
    @Synchronized
    fun uninstall() {
        if (!installed) return
        installed = false
        NetworkingModule.setCustomClientBuilder(null)
    }

    @Synchronized
    fun install(hosts: Set<String>) {
        // OkHttp lower-cases hosts.
        val allowHosts = hosts.map { it.lowercase() }.toSet()
        NetworkingModule.setCustomClientBuilder(
            object : NetworkingModule.CustomClientBuilder {
                override fun apply(builder: OkHttpClient.Builder) {
                    builder.addInterceptor(TugboatOkHttpInterceptor { request -> route(request, allowHosts) })
                }
            },
        )
        installed = true
    }

    private fun route(request: Request, allowHosts: Set<String>): String? {
        if (allowHosts.isNotEmpty() && request.url.host !in allowHosts) return null
        return request.url.encodedPath
    }
}
