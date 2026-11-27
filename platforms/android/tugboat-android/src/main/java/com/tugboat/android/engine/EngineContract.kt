package com.tugboat.android.engine

/**
 * Contract versions the engine reports about itself, read once through
 * [NativeEngine] instead of copied into the host.
 */
internal object EngineContract {
    /**
     * JVM unit tests only: they cannot load `libtugboat_engine`, so Gradle
     * passes the value of `TB_SESSION_ENGINE_FINGERPRINT_SCHEMA_VERSION` from the C
     * header under this name. Never set on a device.
     */
    const val FINGERPRINT_SCHEMA_VERSION_PROPERTY = "tugboat.engine.fingerprintSchemaVersion"

    /**
     * The fingerprint schema version of the identity the engine and the hosts
     * hash (`tb_session_engine_fingerprint_schema_version`). Read when the
     * first anchor is serialized, after the engine library is loaded.
     */
    val fingerprintSchemaVersion: Int by lazy {
        System.getProperty(FINGERPRINT_SCHEMA_VERSION_PROPERTY)?.toIntOrNull()
            ?: NativeEngine.fingerprintSchemaVersion()
    }
}
