package com.tugboat.android

/**
 * What [Tugboat.start] needs. Everything not here comes from the session
 * engine's defaults (stateful-engine.md section 6).
 */
data class TugboatConfig @JvmOverloads constructor(
    val collector: CollectorConfig,
    val app: AppInfo,
    /** Only [MaskLevel.AllTextAndMedia] exists in this release. */
    val maskLevel: MaskLevel = MaskLevel.AllTextAndMedia,
    /** Records `focus_changed` for text-input focus transitions (engine capability `focusChanges`). */
    val captureFocusChanges: Boolean = false,
    /** Records `system_input` for allowlisted keys such as back (engine capability `systemInput`). */
    val captureSystemInput: Boolean = false,
    /** Emits native `scene.inventory` facts after captured frames (engine capability `nativeSceneInventory`). */
    val emitSceneInventory: Boolean = false,
)

/** The collector the SDK delivers to. */
data class CollectorConfig(
    /** For example `https://collector.example.com`; request paths are resolved against it. */
    val baseUrl: String,
    val apiKey: String,
) {
    /** Never prints the API key. */
    override fun toString(): String = "CollectorConfig(baseUrl=$baseUrl)"
}

/**
 * The app as the collector files it. Every field is required: the collector
 * rejects a `session_start` without the version and build number, so
 * [Tugboat.start] refuses to start (and logs why) when one is blank.
 */
data class AppInfo(
    val name: String,
    val version: String,
    val buildNumber: String,
    /** The application id (package name). Also sent as the `X-App-Id` header. */
    val appId: String,
    /** Stable per install; the app owns it (for example a UUID kept in its preferences). */
    val installationId: String,
)

/** What screenshots mask before they are encoded. */
enum class MaskLevel {
    /**
     * Text (every `TextView`, `EditText`, button), media (`ImageView`,
     * `VideoView`), and fail-closed bounds for content the SDK cannot see
     * into (`WebView`, `SurfaceView`, `TextureView`, Compose hosts).
     */
    AllTextAndMedia,
}
