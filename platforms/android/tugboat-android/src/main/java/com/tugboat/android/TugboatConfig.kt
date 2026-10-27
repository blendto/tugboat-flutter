package com.tugboat.android

/**
 * What [Tugboat.start] needs. Everything not here comes from the session
 * engine's defaults (stateful-engine.md section 6). The activation request
 * id is not here: it comes from [Tugboat.activate], as in Flutter.
 */
data class TugboatConfig @JvmOverloads constructor(
    val collector: CollectorConfig,
    val app: AppInfo,
    /**
     * Flutter's `TugboatReplayConfig.enabled`. When `true`,
     * [Tugboat.start] starts a session at once, with no activation request
     * id. When `false` (the default) the SDK is dormant until
     * [Tugboat.activate]: no engine, window callbacks, threads, or network,
     * and nothing recorded; only process-scoped activity lifecycle callbacks
     * keep navigation state. The user id, traits, and event hooks keep their
     * state for the next session. After [Tugboat.deactivate], a `true` here
     * does not start a session again until the next [Tugboat.activate].
     */
    val enabled: Boolean = false,
    /** Only [MaskLevel.AllTextAndMedia] exists in this release. */
    val maskLevel: MaskLevel = MaskLevel.AllTextAndMedia,
    /** Records `focus_changed` for text-input focus transitions (engine capability `focusChanges`). */
    val captureFocusChanges: Boolean = false,
    /** Records `system_input` for allowlisted keys such as back (engine capability `systemInput`). */
    val captureSystemInput: Boolean = false,
    /** Records bounded `capture_diagnostic` events (engine capability `captureDiagnostics`). */
    val captureDiagnostics: Boolean = false,
    /**
     * Passed on `session.start` when non-blank; omitted when null or blank
     * (blank is normalised to omitted, not sent as `""`).
     */
    val explorationRunId: String? = null,
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
     * `VideoView`), fail-closed bounds for content the SDK cannot see
     * into (`WebView`, `SurfaceView`, `TextureView`, Compose hosts), and
     * every view marked with `View.tugboatSensitive()` (with its subtree)
     * or Compose `Modifier.tugboatSensitive()`.
     */
    AllTextAndMedia,
}
