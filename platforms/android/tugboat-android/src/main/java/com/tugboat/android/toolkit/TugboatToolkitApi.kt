package com.tugboat.android.toolkit

/**
 * Marks the toolkit-region seam: the contract between `tugboat-android`'s
 * Views adapter and Tugboat's own toolkit modules (`tugboat-compose`). It is
 * public only because Kotlin `internal` does not cross Gradle modules. It is
 * not app API, has no compatibility promise, and needs an explicit opt-in.
 */
@RequiresOptIn(
    level = RequiresOptIn.Level.ERROR,
    message = "Tugboat's toolkit-region seam is for Tugboat's own toolkit modules, not for apps.",
)
@Retention(AnnotationRetention.BINARY)
@Target(AnnotationTarget.CLASS, AnnotationTarget.FUNCTION, AnnotationTarget.PROPERTY)
annotation class TugboatToolkitApi
