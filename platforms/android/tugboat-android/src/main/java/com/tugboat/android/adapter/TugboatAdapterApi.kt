package com.tugboat.android.adapter

/**
 * Marks the HTTP-client adapter seam: the contract between `tugboat-android`
 * and Tugboat's own network adapters (`tugboat-okhttp`). It is public only
 * because Kotlin `internal` does not cross Gradle modules. It is not app API,
 * has no compatibility promise, and needs an explicit opt-in. Apps record
 * calls with [com.tugboat.android.Tugboat.beginNetworkCall].
 */
@RequiresOptIn(
    level = RequiresOptIn.Level.ERROR,
    message = "Tugboat's HTTP-client adapter seam is for Tugboat's own network adapters, not for apps.",
)
@Retention(AnnotationRetention.BINARY)
@Target(AnnotationTarget.CLASS, AnnotationTarget.FUNCTION, AnnotationTarget.PROPERTY)
annotation class TugboatAdapterApi
