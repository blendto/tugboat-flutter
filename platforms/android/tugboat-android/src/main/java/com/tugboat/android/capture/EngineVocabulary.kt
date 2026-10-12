package com.tugboat.android.capture

/**
 * `capture.result` vocabulary the engine is gaining (branch
 * `engine/mask-coverage`): `failure: "secureWindow"` and
 * `frame.maskCoverage {mode, reasons}`. Sending either before the engine
 * accepts it would reject the whole message, so each is off until that
 * engine change merges.
 *
 * TODO(ADR 0009, engine/mask-coverage): set both to true when it merges.
 */
internal object EngineVocabulary {
    /** Off: a `FLAG_SECURE` window is answered `failed readbackFailed`. */
    const val SECURE_WINDOW_FAILURE = false

    /** Off: the Views mask coverage is computed but not sent. */
    const val FRAME_MASK_COVERAGE = false
}
