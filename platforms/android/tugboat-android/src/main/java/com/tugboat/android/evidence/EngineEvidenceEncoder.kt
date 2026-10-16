package com.tugboat.android.evidence

import com.tugboat.android.ParameterPolicy

/**
 * The engine's evidence encoding (`core/session-engine/docs/evidence-messages.md`):
 * the host obligations of its section 4, and nothing more. Names, sources,
 * methods, and routes go raw; the engine trims, validates, and bounds them,
 * applies the policy and every limit, and computes `durationMs`.
 *
 * - Values (section 2, 4.1): typed Kotlin values in the engine's value grammar.
 * - Transform (4.3): the closure runs here, once per valid key among the first
 *   64 entries, in order.
 * - The mandatory bounds of 4.4 (parameters) and 4.5 (error bodies): they
 *   bound this host's work and the message, and only leave out what Dart
 *   never reads.
 */
internal object EngineEvidenceEncoder : EvidenceEncoder {
    override fun externalEvent(event: ExternalEventInput): String {
        val out = StringBuilder(128)
        out.append("{\"name\":").appendJsonString(event.name)
        event.source?.let { out.append(",\"source\":").appendJsonString(it) }
        out.append(",\"policy\":{\"mode\":\"").append(event.policy.modeWireName()).append('"')
        if (event.policy.mode == ParameterPolicy.Mode.AllowList) {
            out.append(",\"allowedKeys\":[")
            event.policy.allowedKeys.forEachIndexed { index, key ->
                if (index > 0) out.append(',')
                out.appendJsonString(key)
            }
            out.append(']')
        }
        out.append('}')
        val parameters = event.parameters
        if (!parameters.isNullOrEmpty()) {
            out.append(",\"parameters\":")
            ParameterWriter(out, event.policy).writeParameters(parameters)
        }
        out.append(",\"atMonoUs\":").append(event.atMonoUs)
        return out.append('}').toString()
    }

    override fun networkCall(call: NetworkCallInput): String {
        val out = StringBuilder(128)
        out.append("{\"method\":").appendJsonString(call.method)
        out.append(",\"route\":").appendJsonString(call.route)
        out.append(",\"startMonoUs\":").append(call.startMonoUs)
        out.append(",\"endMonoUs\":").append(call.endMonoUs)
        call.statusCode?.let { out.append(",\"statusCode\":").append(it) }
        out.append(",\"outcome\":\"").append(call.outcome.wireName()).append('"')
        call.attemptCount?.let { out.append(",\"attemptCount\":").append(it) }
        // Bodies of other statuses are never read (4.5).
        val status = call.statusCode
        if (status != null && status >= ERROR_STATUS) writeErrorBody(out, call.errorResponseBody)
        return out.append('}').toString()
    }

    /** A `String` is a text body, a `ByteArray` no body, anything else a value. */
    private fun writeErrorBody(out: StringBuilder, body: Any?) {
        if (body == null || body is ByteArray) return
        out.append(",\"errorResponseBody\":{\"value\":")
        if (body is String) out.appendJsonString(textBodyPrefix(body)) else BodyWriter(out).writeRoot(body)
        out.append('}')
    }

    /**
     * Any prefix of whole characters longer than 4096 UTF-8 bytes is exact
     * (4.5). 4097 UTF-16 units are at least 4097 bytes; a cut that would split
     * a surrogate pair keeps the pair.
     */
    private fun textBodyPrefix(body: String): String {
        if (body.length <= BODY_STRING_UNITS) return body
        var end = BODY_STRING_UNITS
        if (body[end - 1].isHighSurrogate() && body[end].isLowSurrogate()) end++
        return body.substring(0, end)
    }

    private fun ParameterPolicy.modeWireName() = when (mode) {
        ParameterPolicy.Mode.NamesOnly -> "names_only"
        ParameterPolicy.Mode.AllowList -> "allow_list"
        ParameterPolicy.Mode.Transform -> "transform"
        ParameterPolicy.Mode.AllowAll -> "allow_all"
    }

    private fun NetworkOutcome.wireName() = when (this) {
        NetworkOutcome.Response -> "response"
        NetworkOutcome.NetworkError -> "network_error"
        NetworkOutcome.Cancelled -> "cancelled"
    }

    // Section 3.1 / 4.3 / 4.5, parameters.
    const val MAX_TOP_LEVEL_ENTRIES = 64
    const val MAX_KEY_UNITS = 128

    /** Parameter values at this depth or deeper (top level is 1) are unsupported (4.4). */
    const val PARAMETER_UNSUPPORTED_DEPTH = 5
    const val MAX_PARAMETER_STRING_UNITS = 1024

    /** Counted slots (list and iterable items, valid-key map entries) across the whole parameters tree. */
    const val PARAMETER_ITEM_BUDGET = 256

    // Section 3.2 / 4.4 / 4.5, error bodies.
    const val ERROR_STATUS = 400

    /** Error-body collections at this depth or deeper (the root is 0) are unsupported (4.4). */
    const val BODY_UNSUPPORTED_COLLECTION_DEPTH = 6
    const val BODY_ITEMS_SENT = 128
    const val BODY_STRING_UNITS = 4097
    const val BODY_NODES_SENT = 4097
}

/**
 * Writes the parameters map (section 4.4): invalid keys as `nonStringKeys`
 * runs at every level, the first 64 top-level entries, the policy's reads,
 * the transform, and one item budget for the whole tree.
 */
private class ParameterWriter(private val out: StringBuilder, private val policy: ParameterPolicy) {
    /** Collections currently being written, innermost last; the parameters map itself is never one. */
    private val ancestors = ArrayList<Any>()

    /** Counted slots sent so far, across every read value (`c` in 4.4). */
    private var items = 0

    fun writeParameters(parameters: Map<*, *>) {
        out.append("{\"map\":[")
        val entries = EntryList(out)
        val iterator = parameters.entries.iterator()
        var sent = 0
        while (sent < EngineEvidenceEncoder.MAX_TOP_LEVEL_ENTRIES && iterator.hasNext()) {
            val (key, value) = iterator.next()
            sent++
            if (!isValidKey(key)) {
                entries.nonStringKey()
                continue
            }
            entries.beginEntry(key as String)
            writeTopLevelValue(key, value)
            out.append(']')
        }
        entries.finish()
        out.append(']')
        if (iterator.hasNext()) out.append(",\"omitted\":").append(parameters.size - sent)
        out.append('}')
    }

    /** Values the engine never reads are sent as `null`, unread. */
    private fun writeTopLevelValue(key: String, value: Any?) {
        when (policy.mode) {
            ParameterPolicy.Mode.NamesOnly -> out.append("null")
            ParameterPolicy.Mode.AllowList -> if (key in policy.allowedKeys) writeValue(value, 1) else out.append("null")
            ParameterPolicy.Mode.Transform -> writeTransformed(key, value)
            ParameterPolicy.Mode.AllowAll -> writeValue(value, 1)
        }
    }

    private fun writeTransformed(key: String, value: Any?) {
        val transform = policy.transform
        val result = try {
            if (transform == null) ParameterPolicy.DROP else transform.apply(key, value)
        } catch (_: Throwable) {
            ParameterPolicy.DROP
        }
        if (result === ParameterPolicy.DROP) out.append("{\"drop\":true}") else writeValue(result, 1)
    }

    private fun writeValue(value: Any?, depth: Int) {
        if (depth >= EngineEvidenceEncoder.PARAMETER_UNSUPPORTED_DEPTH) {
            out.append(UNSUPPORTED)
            return
        }
        if (value is String) {
            if (value.length > EngineEvidenceEncoder.MAX_PARAMETER_STRING_UNITS) out.append(UNSUPPORTED) else out.appendJsonString(value)
            return
        }
        if (out.appendScalar(value)) return
        val ref = refTo(ancestors, value)
        if (ref > 0) {
            out.append("{\"ref\":").append(ref).append('}')
            return
        }
        ancestors.add(value!!)
        try {
            writeCollection(value, depth)
        } finally {
            ancestors.removeAt(ancestors.size - 1)
        }
    }

    private fun writeCollection(value: Any, depth: Int) {
        when (value) {
            is List<*> -> writeItems(value.iterator(), depth, tag = "list")
            is Array<*> -> writeItems(value.iterator(), depth, tag = "list")
            is Map<*, *> -> writeMap(value, depth)
            is Iterable<*> -> writeItems(value.iterator(), depth, tag = "iterable")
            else -> out.append(UNSUPPORTED)
        }
    }

    /** False, without taking a slot, once the budget is spent: the collection then ends with `"omitted": 1`. */
    private fun takeSlot(): Boolean {
        if (items >= EngineEvidenceEncoder.PARAMETER_ITEM_BUDGET) return false
        items++
        return true
    }

    /** A list is a bare array unless the budget cuts it. */
    private fun writeItems(iterator: Iterator<*>, depth: Int, tag: String) {
        val start = out.length
        out.append('[')
        var sent = 0
        var cut = false
        while (iterator.hasNext()) {
            if (!takeSlot()) {
                cut = true
                break
            }
            if (sent++ > 0) out.append(',')
            writeValue(iterator.next(), depth + 1)
        }
        out.append(']')
        if (tag == "list" && !cut) return
        out.insert(start, "{\"$tag\":")
        if (cut) out.append(",\"omitted\":1")
        out.append('}')
    }

    private fun writeMap(map: Map<*, *>, depth: Int) {
        out.append("{\"map\":[")
        val entries = EntryList(out)
        val iterator = map.entries.iterator()
        var cut = false
        while (iterator.hasNext()) {
            val (key, value) = iterator.next()
            if (!isValidKey(key)) {
                entries.nonStringKey()
                continue
            }
            if (!takeSlot()) {
                cut = true
                break
            }
            entries.beginEntry(key as String)
            writeValue(value, depth + 1)
            out.append(']')
        }
        entries.finish()
        out.append(']')
        if (cut) out.append(",\"omitted\":1")
        out.append('}')
    }

    private fun isValidKey(key: Any?) = key is String && key.isNotEmpty() && key.length <= EngineEvidenceEncoder.MAX_KEY_UNITS
}

/**
 * Writes an error body (section 4.5): collections at depth 6 or more
 * unsupported, the first 128 items of each collection with `omitted`, strings
 * and keys cut to 4097 units, and nothing more once 4097 nodes are written,
 * all exact because Dart's encoding is past 4096 bytes by then.
 */
private class BodyWriter(private val out: StringBuilder) {
    private val ancestors = ArrayList<Any>()
    private var nodes = 0

    /** Above zero inside an `iterable`, whose contents the node count leaves out. */
    private var uncounted = 0

    private val stopped: Boolean
        get() = nodes >= EngineEvidenceEncoder.BODY_NODES_SENT

    fun writeRoot(body: Any) = writeValue(body, 0)

    private fun writeValue(value: Any?, depth: Int) {
        if (value is String) {
            count()
            out.appendJsonString(cut(value))
            return
        }
        if (out.appendScalar(value)) {
            // unsupported values and non-finite doubles are not nodes.
            if (isNode(value)) count()
            return
        }
        if (!isCollection(value)) {
            out.append(UNSUPPORTED)
            return
        }
        if (depth >= EngineEvidenceEncoder.BODY_UNSUPPORTED_COLLECTION_DEPTH) {
            out.append(UNSUPPORTED)
            return
        }
        val ref = refTo(ancestors, value)
        if (ref > 0) {
            out.append("{\"ref\":").append(ref).append('}')
            return
        }
        ancestors.add(value!!)
        try {
            writeCollection(value, depth)
        } finally {
            ancestors.removeAt(ancestors.size - 1)
        }
    }

    private fun writeCollection(value: Any, depth: Int) {
        when (value) {
            is List<*> -> writeList(value.iterator(), value.size, depth)
            is Array<*> -> writeList(value.iterator(), value.size, depth)
            is Map<*, *> -> writeMap(value, depth)
            is Iterable<*> -> writeIterable(value.iterator(), depth)
        }
    }

    private fun writeList(items: Iterator<*>, size: Int, depth: Int) {
        count()
        val start = out.length
        out.append('[')
        val sent = writeItems(items, depth)
        out.append(']')
        if (!stopped && size > sent) {
            out.insert(start, "{\"list\":").append(",\"omitted\":").append(size - sent).append('}')
        }
    }

    private fun writeIterable(items: Iterator<*>, depth: Int) {
        uncounted++
        try {
            out.append("{\"iterable\":[")
            writeItems(items, depth)
            out.append(']')
            if (!stopped && items.hasNext()) out.append(",\"omitted\":1")
            out.append('}')
        } finally {
            uncounted--
        }
    }

    private fun writeItems(items: Iterator<*>, depth: Int): Int {
        var sent = 0
        while (sent < EngineEvidenceEncoder.BODY_ITEMS_SENT && !stopped && items.hasNext()) {
            if (sent > 0) out.append(',')
            writeValue(items.next(), depth + 1)
            sent++
        }
        return sent
    }

    /** A non-string key uses up one of the 128 items. */
    private fun writeMap(map: Map<*, *>, depth: Int) {
        count()
        out.append("{\"map\":[")
        val entries = EntryList(out)
        val iterator = map.entries.iterator()
        var sent = 0
        while (sent < EngineEvidenceEncoder.BODY_ITEMS_SENT && !stopped && iterator.hasNext()) {
            val (key, value) = iterator.next()
            sent++
            if (key !is String) {
                entries.nonStringKey()
                continue
            }
            entries.beginEntry(cut(key))
            writeValue(value, depth + 1)
            out.append(']')
        }
        entries.finish()
        out.append(']')
        if (!stopped && map.size > sent) out.append(",\"omitted\":").append(map.size - sent)
        out.append('}')
    }

    private fun count() {
        if (uncounted == 0) nodes++
    }

    private fun cut(value: String) =
        if (value.length > EngineEvidenceEncoder.BODY_STRING_UNITS) value.substring(0, EngineEvidenceEncoder.BODY_STRING_UNITS) else value

    private fun isNode(value: Any?) = when (value) {
        null, is Boolean, is Byte, is Short, is Int, is Long -> true
        is Double -> value.isFinite()
        is Float -> value.isFinite()
        else -> false
    }

    private fun isCollection(value: Any?) = value is List<*> || value is Array<*> || value is Map<*, *> || value is Iterable<*>
}

/** Map entries: `[key, value]`, with consecutive non-string keys as one `{"nonStringKeys": n}`. */
private class EntryList(private val out: StringBuilder) {
    private var written = 0
    private var nonStringRun = 0

    fun nonStringKey() {
        nonStringRun++
    }

    /** Writes `[key,`; the caller writes the value and `]`. */
    fun beginEntry(key: String) {
        flush()
        separate()
        out.append('[').appendJsonString(key).append(',')
    }

    fun finish() = flush()

    private fun flush() {
        if (nonStringRun == 0) return
        separate()
        out.append("{\"nonStringKeys\":").append(nonStringRun).append('}')
        nonStringRun = 0
    }

    private fun separate() {
        if (written++ > 0) out.append(',')
    }
}

private const val UNSUPPORTED = "{\"unsupported\":true}"

/** Levels up to the same instance among [ancestors] (1 is the innermost), or 0. */
private fun refTo(ancestors: List<Any>, value: Any?): Int {
    if (value == null) return 0
    for (i in ancestors.indices.reversed()) {
        if (ancestors[i] === value) return ancestors.size - i
    }
    return 0
}

/**
 * Writes `null`, a boolean, an integer (`Byte`, `Short`, `Int`, `Long`), or a
 * `double` (`Float` widened); `{"unsupported": true}` for any other value
 * that is not a string or collection. False when [value] is a string or a
 * collection, which the caller writes.
 */
private fun StringBuilder.appendScalar(value: Any?): Boolean {
    when (value) {
        null -> append("null")
        is Boolean -> append(value)
        is Byte, is Short, is Int, is Long -> append((value as Number).toLong())
        is Double -> appendDouble(value)
        is Float -> appendDouble(value.toDouble())
        is String, is List<*>, is Array<*>, is Map<*, *>, is Iterable<*> -> return false
        else -> append(UNSUPPORTED)
    }
    return true
}

private fun StringBuilder.appendDouble(value: Double) {
    append("{\"double\":")
    when {
        value.isNaN() -> append("\"NaN\"")
        value == Double.POSITIVE_INFINITY -> append("\"Infinity\"")
        value == Double.NEGATIVE_INFINITY -> append("\"-Infinity\"")
        value == 0.0 && 1.0 / value < 0 -> append("\"-0.0\"")
        // Kotlin prints 1.0, 1.0E10, 1.0E-5: all JSON numbers.
        else -> append(value.toString())
    }
    append('}')
}

/**
 * A JSON string. Lone surrogates are written as `\uXXXX` (org.json writes
 * them raw, and UTF-8 conversion would replace them); pairs are kept.
 */
internal fun StringBuilder.appendJsonString(value: String): StringBuilder {
    append('"')
    var i = 0
    while (i < value.length) {
        val c = value[i]
        when {
            c == '"' -> append("\\\"")
            c == '\\' -> append("\\\\")
            c == '\n' -> append("\\n")
            c == '\r' -> append("\\r")
            c == '\t' -> append("\\t")
            c == '\b' -> append("\\b")
            c == '\u000C' -> append("\\f")
            c < ' ' -> appendUnicodeEscape(c)
            c.isHighSurrogate() && i + 1 < value.length && value[i + 1].isLowSurrogate() -> {
                append(c).append(value[i + 1])
                i++
            }
            c.isSurrogate() -> appendUnicodeEscape(c)
            else -> append(c)
        }
        i++
    }
    return append('"')
}

private fun StringBuilder.appendUnicodeEscape(c: Char) {
    append("\\u")
    val hex = Integer.toHexString(c.code)
    repeat(4 - hex.length) { append('0') }
    append(hex)
}
