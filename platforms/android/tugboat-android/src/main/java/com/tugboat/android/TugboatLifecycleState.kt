package com.tugboat.android

import java.util.Locale

/**
 * Where the SDK is in its capture lifecycle ([Tugboat.lifecycleState]); the
 * same four states as Flutter's `TugboatLifecycleState`.
 */
enum class TugboatLifecycleState {
    /** No session: nothing is recorded. The state before [Tugboat.activate] when `TugboatConfig.enabled` is `false`. */
    DORMANT,

    /**
     * A session is requested and not yet recording: [Tugboat.activate] was
     * called (also before [Tugboat.start], until `start` runs), or a session
     * is replacing one with another activation request id.
     */
    STARTING,

    /** A session is recording. */
    ACTIVE,

    /** [Tugboat.deactivate] or [Tugboat.stop] was called and the session has not yet posted `session.end`. */
    STOPPING,
}

/** Flutter's name for the state (`dormant`, `starting`, `active`, `stopping`), as `TUGBOAT_HEALTH` prints it. */
internal val TugboatLifecycleState.wireName: String
    get() = name.lowercase(Locale.ROOT)
