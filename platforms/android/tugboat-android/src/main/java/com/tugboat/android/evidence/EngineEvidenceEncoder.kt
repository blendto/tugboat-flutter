package com.tugboat.android.evidence

/**
 * The engine's input value encoding for evidence.
 *
 * WIP: waiting for the engine's encoding contract (value encoding, transform
 * contract, elision rules, key order). Until it lands every call throws, so
 * evidence is dropped and logged.
 */
internal object EngineEvidenceEncoder : EvidenceEncoder {
    override fun externalEvent(event: ExternalEventInput): String = pending()

    override fun networkCall(call: NetworkCallInput): String = pending()

    private fun pending(): Nothing = throw UnsupportedOperationException("evidence encoding is not implemented yet")
}
