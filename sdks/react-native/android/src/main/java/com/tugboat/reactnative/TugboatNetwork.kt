package com.tugboat.reactnative

import com.facebook.react.modules.network.NetworkingModule
import com.tugboat.android.okhttp.TugboatOkHttpInterceptor
import okhttp3.Request

/**
 * Records `fetch` and `XMLHttpRequest` calls: both go through React Native's OkHttp
 * client. The route is the URL path, never the URL or query. There is one slot for a
 * custom client builder, so this replaces an app's own.
 */
internal object TugboatNetwork {
    fun install(allowHosts: Set<String>) {
        NetworkingModule.setCustomClientBuilder(
            NetworkingModule.CustomClientBuilder { builder ->
                builder.addInterceptor(TugboatOkHttpInterceptor { request -> route(request, allowHosts) })
            },
        )
    }

    private fun route(request: Request, allowHosts: Set<String>): String? {
        if (allowHosts.isNotEmpty() && request.url.host !in allowHosts) return null
        return request.url.encodedPath
    }
}
