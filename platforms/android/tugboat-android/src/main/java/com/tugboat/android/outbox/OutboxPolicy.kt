package com.tugboat.android.outbox

import com.tugboat.android.TugboatConfig

/** The outbox bounds of one config (W11 design 3.4), each at least 1. */
internal class OutboxSettings(
    val maxBytes: Long,
    val maxEntries: Int,
    val maxAgeMs: Long,
    val maxAttempts: Int,
) {
    companion object {
        val DEFAULT = OutboxSettings(20L * 1024 * 1024, 1000, 72L * 60 * 60 * 1000, 8)

        fun of(config: TugboatConfig) = OutboxSettings(
            maxBytes = config.outboxMaxBytes.coerceAtLeast(1),
            maxEntries = config.outboxMaxEntries.coerceAtLeast(1),
            maxAgeMs = config.outboxMaxAgeMs.coerceAtLeast(1),
            maxAttempts = config.outboxMaxAttempts.coerceAtLeast(1),
        )
    }
}

/** When the outbox is erased (W11 design 3.5, as agreed by Chinmay on 2026-10-27). */
internal object OutboxPolicy {
    /**
     * Whether `Tugboat.start` with [config] deletes every kept entry: only
     * when the outbox is off. `enabled == false` is dormant (a session comes
     * later with `activate`), not opt-out, so it keeps them.
     * `Tugboat.clearPendingData` is the other wipe.
     */
    fun wipeAtStart(config: TugboatConfig): Boolean = !config.durableOutbox

    /**
     * The entries to evict, in order, so the outbox fits [settings]: entries
     * of other sessions first, then frames before events, then oldest first.
     * Lifecycle entries leave only by age, and a key with a request in flight
     * ([isActive]) never.
     */
    fun evictions(
        entries: List<StoredEntry>,
        settings: OutboxSettings,
        isOrphan: (StoredEntry) -> Boolean,
        isActive: (String) -> Boolean,
    ): List<StoredEntry> {
        var bytes = entries.sumOf { it.bytes }
        var count = entries.size
        if (bytes <= settings.maxBytes && count <= settings.maxEntries) return emptyList()
        val candidates = entries
            .filter { it.lane != OutboxLane.LIFECYCLE && !isActive(it.key) }
            .sortedWith(
                compareBy<StoredEntry>({ if (isOrphan(it)) 0 else 1 }, { if (it.lane == OutboxLane.FRAMES) 0 else 1 })
                    .thenBy { it.createdAtWallMs }
                    .thenBy { it.key },
            )
        val evicted = ArrayList<StoredEntry>()
        for (entry in candidates) {
            if (bytes <= settings.maxBytes && count <= settings.maxEntries) break
            evicted += entry
            bytes -= entry.bytes
            count--
        }
        return evicted
    }
}
