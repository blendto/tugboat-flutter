package com.tugboat.android.engine

/** Mirrors `tb_session_status` in `tb_session_engine.h`; [code] is the C value. */
internal enum class EngineStatus(val code: Int, val wireName: String) {
    OK(0, "ok"),
    INVALID_ARGUMENT(1, "invalid_argument"),
    ABI_MISMATCH(2, "abi_mismatch"),
    MALFORMED_MESSAGE(3, "malformed_message"),
    INVALID_MESSAGE(4, "invalid_message"),
    UNSUPPORTED_MESSAGE(5, "unsupported_message"),
    CONTRACT_MISMATCH(6, "contract_mismatch"),
    MESSAGE_TOO_LARGE(7, "message_too_large"),
    BUSY(8, "busy"),
    OUT_OF_MEMORY(9, "out_of_memory"),
    INTERNAL_ERROR(10, "internal_error"),
    ;

    companion object {
        private val byCode = values().associateBy(EngineStatus::code)

        /** Codes this build does not know are treated as [INTERNAL_ERROR]. */
        fun fromCode(code: Int): EngineStatus = byCode[code] ?: INTERNAL_ERROR
    }
}
