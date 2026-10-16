package com.tugboat.android.evidence

import com.tugboat.android.ParameterPolicy
import org.json.JSONArray
import org.json.JSONObject

/**
 * The shared `conformance/evidence` fixtures, read back into the Kotlin
 * values a host would pass. Each fixture's `input` is an engine message in
 * the value encoding; [hostEvent] and [hostCall] invert that encoding into
 * typed Kotlin objects (lists, sets, ordered maps, cycles by identity), so
 * the encoder can be checked against the fixture input (unit tests) and,
 * through the real engine, against the fixture's expected data (device
 * tests). Shared by the `test` and `androidTest` source sets.
 */
internal class EvidenceFixture(val path: String, json: JSONObject) {
    val name: String = json.getString("name")
    val kind: String = json.getString("kind")
    val input: JSONObject = json.getJSONObject("input")

    /** `expected.data`: an object, or [JSONObject.NULL] when nothing is recorded. */
    val expectedData: Any = json.getJSONObject("expected").get("data")

    /** Empty means every runner; the C++-only divergences name `cpp`. */
    val runners: List<String> = json.optJSONArray("runners")?.let { array -> List(array.length()) { array.getString(it) } }.orEmpty()

    val isExternalEvent get() = kind == EvidenceMessages.EXTERNAL_EVENT
    val isNetworkCall get() = kind == EvidenceMessages.NETWORK_CALL

    /** The engine message's `at.monoUs`, as the C++ runner sends it. */
    fun atMonoUs(): Long = when {
        isNetworkCall -> input.optLong("endMonoUs", input.getLong("startMonoUs"))
        else -> input.optLong("atMonoUs", 0)
    }

    /**
     * Why this fixture is not something the manual Kotlin API can send, or
     * null. `jsonText` bodies come from a host that did not decode the body
     * (an HTTP client adapter, slice N2), and engine-only divergences are not
     * run by hosts.
     */
    fun notForManualApi(): String? = when {
        runners.isNotEmpty() && "kotlin" !in runners -> "runners: $runners"
        isNetworkCall && input.optJSONObject("errorResponseBody")?.has("jsonText") == true -> "a jsonText body (HTTP adapters, N2)"
        else -> null
    }

    fun hostEvent(): ExternalEventInput {
        val policyJson = input.getJSONObject("policy")
        val parameters = input.optJSONObject("parameters")?.let { decodeParameters(it) }
        val policy = when (val mode = policyJson.getString("mode")) {
            "names_only" -> ParameterPolicy.namesOnly
            "allow_all" -> ParameterPolicy.allowAll
            "allow_list" -> {
                val keys = policyJson.getJSONArray("allowedKeys")
                ParameterPolicy.allowList(List(keys.length()) { keys.getString(it) }.toCollection(LinkedHashSet()))
            }
            // The fixture's values are the transform's results; the drop tag is the sentinel.
            "transform" -> ParameterPolicy.transform { key, _ -> parameters?.get(key) }
            else -> error("unknown mode $mode")
        }
        return ExternalEventInput(
            name = input.getString("name"),
            source = if (input.has("source")) input.getString("source") else null,
            policy = policy,
            parameters = parameters,
            atMonoUs = atMonoUs(),
        )
    }

    fun hostCall(): NetworkCallInput {
        val body = input.optJSONObject("errorResponseBody")?.let { decodeValue(it.get("value"), ArrayList()) }
        return NetworkCallInput(
            method = input.getString("method"),
            route = input.getString("route"),
            startMonoUs = input.getLong("startMonoUs"),
            endMonoUs = atMonoUs(),
            statusCode = if (input.has("statusCode")) input.getInt("statusCode") else null,
            outcome = when (val outcome = input.getString("outcome")) {
                "response" -> NetworkOutcome.Response
                "network_error" -> NetworkOutcome.NetworkError
                "cancelled" -> NetworkOutcome.Cancelled
                else -> error("unknown outcome $outcome")
            },
            attemptCount = if (input.has("attemptCount")) input.getInt("attemptCount") else null,
            errorResponseBody = body,
        )
    }

    /** The encoder's message for this fixture's host values. */
    fun encode(): String = if (isNetworkCall) EngineEvidenceEncoder.networkCall(hostCall()) else EngineEvidenceEncoder.externalEvent(hostEvent())

    /** The parameters map is never an ancestor of its values (evidence-messages.md section 2). */
    private fun decodeParameters(json: JSONObject): Map<Any?, Any?> = decodeMap(json, ArrayList(), register = false)

    private fun decodeValue(json: Any?, ancestors: MutableList<Any>): Any? = when (json) {
        JSONObject.NULL, null -> null
        is Boolean, is String -> json
        is Int -> json.toLong()
        is Long -> json
        is JSONArray -> decodeItems(json, 0, ArrayList(), ancestors)
        is JSONObject -> decodeTagged(json, ancestors)
        else -> error("$path: a bare number must be an integer: $json")
    }

    private fun decodeTagged(json: JSONObject, ancestors: MutableList<Any>): Any? = when {
        json.has("double") -> decodeDouble(json.get("double"))
        json.has("list") -> decodeItems(json.getJSONArray("list"), json.optInt("omitted"), ArrayList(), ancestors)
        json.has("iterable") -> FixtureIterable(decodeItems(json.getJSONArray("iterable"), json.optInt("omitted"), ArrayList(), ancestors))
        json.has("map") -> decodeMap(json, ancestors, register = true)
        json.has("ref") -> ancestors[ancestors.size - json.getInt("ref")]
        json.has("unsupported") -> Unsupported
        json.has("drop") -> ParameterPolicy.DROP
        else -> error("$path: unknown tag $json")
    }

    private fun decodeDouble(value: Any): Double = when (value) {
        "NaN" -> Double.NaN
        "Infinity" -> Double.POSITIVE_INFINITY
        "-Infinity" -> Double.NEGATIVE_INFINITY
        "-0.0" -> -0.0
        is Number -> value.toDouble()
        else -> error("$path: bad double $value")
    }

    /** Items, then [omitted] stand-ins: omitted items are unsupported values. */
    private fun decodeItems(json: JSONArray, omitted: Int, out: ArrayList<Any?>, ancestors: MutableList<Any>): ArrayList<Any?> {
        ancestors.add(out)
        for (i in 0 until json.length()) out.add(decodeValue(json.get(i), ancestors))
        repeat(omitted) { out.add(Unsupported) }
        ancestors.removeAt(ancestors.size - 1)
        return out
    }

    /** `nonStringKeys` runs become distinct non-string keys; omitted entries string keys with unsupported values. */
    private fun decodeMap(json: JSONObject, ancestors: MutableList<Any>, register: Boolean): LinkedHashMap<Any?, Any?> {
        val out = LinkedHashMap<Any?, Any?>()
        if (register) ancestors.add(out)
        val entries = json.getJSONArray("map")
        for (i in 0 until entries.length()) {
            val entry = entries.get(i)
            if (entry is JSONArray) {
                out[entry.getString(0)] = decodeValue(entry.get(1), ancestors)
            } else {
                repeat((entry as JSONObject).getInt("nonStringKeys")) { out[NonStringKey()] = null }
            }
        }
        repeat(json.optInt("omitted")) { out["\u0000omitted-$it"] = Unsupported }
        if (register) ancestors.removeAt(ancestors.size - 1)
        return out
    }

    override fun toString() = path

    /** A value the encoding has no type for. */
    object Unsupported {
        override fun toString() = "Unsupported"
    }

    /** A key that is not a string; equal only to itself. */
    class NonStringKey

    /** An `Iterable` that is not a `List` or `Collection` (a set would merge equal items). */
    class FixtureIterable(private val items: List<Any?>) : Iterable<Any?> {
        override fun iterator() = items.iterator()
    }

    companion object {
        /** Every fixture, from `(path, text)` pairs, in path order. */
        fun load(files: List<Pair<String, String>>): List<EvidenceFixture> =
            files.sortedBy { it.first }.map { (path, text) -> EvidenceFixture(path, JSONObject(text)) }
    }
}
