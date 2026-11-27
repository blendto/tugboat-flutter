package com.tugboat.android.views.identity

/** Fingerprint confidence tiers, lowest first; [floor] takes the weakest. */
internal enum class Confidence(val wire: String) {
    Low("low"),
    Medium("medium"),
    High("high"),
    ;

    companion object {
        fun floor(vararg tiers: Confidence): Confidence = tiers.minByOrNull { it.ordinal } ?: High
    }
}
