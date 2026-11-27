package com.tugboat.android.engine

/**
 * Contract versions the engine reports about itself, read once through
 * [NativeEngine] instead of copied into the host.
 */
internal object EngineContract {
    /**
     * Read only when `libtugboat_engine` cannot be loaded, which is the case in
     * JVM unit tests alone (on a device the engine is the only source): Gradle
     * passes the value of `TB_SESSION_ENGINE_FINGERPRINT_SCHEMA_VERSION` from
     * the C header under this name.
     */
    const val FINGERPRINT_SCHEMA_VERSION_PROPERTY = "tugboat.engine.fingerprintSchemaVersion"

    /**
     * The fingerprint schema version of the identity the engine and the hosts
     * hash (`tb_session_engine_fingerprint_schema_version`). Read when the
     * first anchor is serialized. The engine library always wins; the test
     * property is consulted only when the library does not load.
     */
    val fingerprintSchemaVersion: Int by lazy {
        try {
            NativeEngine.fingerprintSchemaVersion()
        } catch (failure: LinkageError) {
            System.getProperty(FINGERPRINT_SCHEMA_VERSION_PROPERTY)?.toIntOrNull() ?: throw failure
        }
    }
}
