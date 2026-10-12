package com.tugboat.android.host

import com.tugboat.android.BuildConfig

/** Collector endpoint and the app and device values every request carries. */
internal class HostConfig(
    val collectorBaseUrl: String,
    val apiKey: String,
    val appVersion: String,
    val appBuild: String,
    val appId: String,
    val platform: String = "android",
    val sdkVersion: String = BuildConfig.SDK_VERSION,
) {
    /** The Flutter `CollectorHttpSink` default headers, same names and order. */
    fun collectorHeaders(): Map<String, String> = linkedMapOf(
        "X-PMKit-API-Key" to apiKey,
        "X-Tugboat-API-Key" to apiKey,
        "X-Platform" to platform,
        "X-App-Build" to appBuild,
        "X-App-Version" to appVersion,
        "X-App-Id" to appId,
        "X-Sdk-Version" to sdkVersion,
    )

    /** Never prints the API key. */
    override fun toString(): String =
        "HostConfig(collectorBaseUrl=$collectorBaseUrl, appId=$appId, appVersion=$appVersion, " +
            "appBuild=$appBuild, platform=$platform, sdkVersion=$sdkVersion)"
}
