package com.tugboat.android.evidence

import com.tugboat.android.ParameterPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.math.BigDecimal
import java.math.BigInteger

/** The host obligations of `core/session-engine/docs/evidence-messages.md` section 4, byte for byte. */
class EngineEvidenceEncoderTest {
    private fun event(policy: ParameterPolicy, parameters: Map<*, *>?, name: String = "E", source: String? = null) =
        EngineEvidenceEncoder.externalEvent(ExternalEventInput(name, source, policy, parameters, atMonoUs = 7))

    private fun parameters(policy: ParameterPolicy, parameters: Map<*, *>): String {
        val json = event(policy, parameters)
        val prefix = "\"parameters\":"
        val start = json.indexOf(prefix) + prefix.length
        return json.substring(start, json.lastIndexOf(",\"atMonoUs\""))
    }

    private fun value(value: Any?): String = parameters(ParameterPolicy.allowAll, mapOf("v" to value))
        .removePrefix("{\"map\":[[\"v\",").removeSuffix("]]}")

    @Test
    fun anExternalEventSendsItsLabelsRawAndThePolicy() {
        val json = event(
            ParameterPolicy.allowList(setOf("method")),
            linkedMapOf("method" to "email", "count" to 3),
            name = "  USER_LOGIN ",
            source = " analytics",
        )

        assertEquals(
            "{\"name\":\"  USER_LOGIN \",\"source\":\" analytics\",\"policy\":{\"mode\":\"allow_list\",\"allowedKeys\":[\"method\"]}," +
                "\"parameters\":{\"map\":[[\"method\",\"email\"],[\"count\",null]]},\"atMonoUs\":7}",
            json,
        )
    }

    @Test
    fun policiesOtherThanAllowListHaveNoKeysAndNoParametersMeansNone() {
        assertEquals(
            "{\"name\":\"E\",\"policy\":{\"mode\":\"allow_all\"},\"atMonoUs\":7}",
            event(ParameterPolicy.allowAll, null),
        )
        assertEquals(
            "{\"name\":\"E\",\"policy\":{\"mode\":\"names_only\"},\"atMonoUs\":7}",
            event(ParameterPolicy.namesOnly, emptyMap<String, Any>()),
        )
        assertEquals(
            "{\"map\":[[\"query\",null],[\"page\",null]]}",
            parameters(ParameterPolicy.namesOnly, linkedMapOf("query" to "chicken soup", "page" to 2)),
        )
        assertTrue(event(ParameterPolicy.transform { _, v -> v }, null).contains("\"mode\":\"transform\""))
    }

    @Test
    fun scalarsFollowTheValueGrammar() {
        assertEquals("null", value(null))
        assertEquals("true", value(true))
        assertEquals("-7", value((-7).toByte()))
        assertEquals("300", value(300.toShort()))
        assertEquals("2147483647", value(Int.MAX_VALUE))
        assertEquals("-9223372036854775808", value(Long.MIN_VALUE))
        assertEquals("{\"double\":1.0}", value(1.0))
        assertEquals("{\"double\":0.5}", value(0.5f))
        assertEquals("{\"double\":0.10000000149011612}", value(0.1f))
        assertEquals("{\"double\":1.0E21}", value(1e21))
        assertEquals("{\"double\":-2.5E-7}", value(-2.5e-7))
        assertEquals("{\"double\":\"NaN\"}", value(Double.NaN))
        assertEquals("{\"double\":\"Infinity\"}", value(Double.POSITIVE_INFINITY))
        assertEquals("{\"double\":\"-Infinity\"}", value(Float.NEGATIVE_INFINITY))
        assertEquals("{\"double\":\"-0.0\"}", value(-0.0))
        assertEquals("{\"double\":0.0}", value(0.0))
    }

    @Test
    fun valuesThatAreNotJsonAreUnsupported() {
        val unsupported = "{\"unsupported\":true}"
        for (v in listOf('c', BigInteger.ONE, BigDecimal.TEN, intArrayOf(1), byteArrayOf(1), Any(), ParameterPolicy.DROP, sequenceOf(1))) {
            assertEquals(v.toString(), unsupported, value(v))
        }
    }

    @Test
    fun stringsEscapeLoneSurrogatesAndKeepPairs() {
        assertEquals("\"a\\ud800b\"", value("a\uD800b"))
        assertEquals("\"\\udc00\"", value("\uDC00"))
        assertEquals("\"x\\ud83d\"", value("x\uD83D"))
        assertEquals("\"\uD83D\uDE00\"", value("\uD83D\uDE00"))
        assertEquals("\"q\\\"b\\\\n\\n\\t\\u0001\\u001f</\"", value("q\"b\\n\n\t\u0001\u001F</"))
    }

    @Test
    fun collectionsAreListsIterablesAndMapsInHostOrder() {
        assertEquals("[1,\"a\"]", value(listOf(1, "a")))
        assertEquals("[1,null]", value(arrayOf(1, null)))
        assertEquals("{\"iterable\":[3,1,2]}", value(linkedSetOf(3, 1, 2)))
        assertEquals(
            "{\"map\":[[\"b\",1],{\"nonStringKeys\":2},[\"a\",2],{\"nonStringKeys\":1}]}",
            value(linkedMapOf<Any?, Any?>("b" to 1, 5 to "secret", null to "secret", "a" to 2, "" to "secret")),
        )
        assertEquals("{\"map\":[]}", value(emptyMap<String, Any>()))
    }

    @Test
    fun cyclesAreRefsToTheAncestorByIdentity() {
        val list = mutableListOf<Any?>(1)
        list.add(list)
        assertEquals("[1,{\"ref\":1}]", value(list))

        val outer = mutableMapOf<String, Any?>()
        outer["inner"] = listOf(outer, listOf(1))
        assertEquals("{\"map\":[[\"inner\",[{\"ref\":2},[1]]]]}", value(outer))

        // Equal is not identical: an equal sibling is written out.
        val a = listOf(1)
        assertEquals("[[1],[1]]", value(listOf(a, listOf(1))))
        assertEquals("[[1],[1]]", value(listOf(a, a)))
    }

    @Test
    fun theParametersMapInsideItselfIsWrittenOnceAsAnOrdinaryMap() {
        val parameters = linkedMapOf<String, Any?>("k" to 1)
        parameters["self"] = parameters

        assertEquals(
            "{\"map\":[[\"k\",1],[\"self\",{\"map\":[[\"k\",1],[\"self\",{\"ref\":1}]]}]]}",
            parameters(ParameterPolicy.allowAll, parameters),
        )
    }

    @Test
    fun parameterValuesAtDepthFiveAreUnsupported() {
        assertEquals("[[[[{\"unsupported\":true}]]]]", value(listOf(listOf(listOf(listOf(1))))))
        assertEquals("[[[[]]]]", value(listOf(listOf(listOf(emptyList<Any>())))))
    }

    @Test
    fun invalidTopLevelKeysAreRunsThatCountTowardsSixtyFour() {
        val parameters = linkedMapOf<Any?, Any?>("ok" to 1, "" to 2, "k".repeat(129) to 3, null to 4, "k".repeat(128) to 5)
        (0 until 70).forEach { parameters[it] = it }

        assertEquals(
            "{\"map\":[[\"ok\",1],{\"nonStringKeys\":3},[\"${"k".repeat(128)}\",5],{\"nonStringKeys\":59}],\"omitted\":11}",
            parameters(ParameterPolicy.allowAll, parameters),
        )
    }

    @Test
    fun theTopLevelSendsSixtyFourEntriesAndCountsTheRest() {
        val many = (0 until 70).associate { "k$it" to it }
        val json = parameters(ParameterPolicy.allowAll, many)

        assertTrue(json.endsWith("[\"k63\",63]],\"omitted\":6}"))
        assertFalse(json.contains("k64"))
        assertFalse(parameters(ParameterPolicy.allowAll, (0 until 64).associate { "k$it" to it }).contains("omitted"))
    }

    @Test
    fun theTransformRunsOnceForEachValidKeyAmongTheFirstSixtyFour() {
        val parameters = linkedMapOf<Any?, Any?>(
            "a" to 1,
            "" to "empty key",
            "x".repeat(129) to "long key",
            7 to "number key",
            "drop" to 2,
            "throws" to 3,
            "nulled" to 4,
            "nested" to listOf(ParameterPolicy.DROP),
        )
        (0 until 60).forEach { parameters["p$it"] = it }
        val calls = mutableListOf<String>()
        val policy = ParameterPolicy.transform { key, value ->
            calls += key
            when (key) {
                "drop" -> ParameterPolicy.DROP
                "throws" -> error("host bug")
                "nulled" -> null
                "nested" -> value
                else -> "t$value"
            }
        }

        val json = parameters(policy, parameters)

        assertEquals(listOf("a", "drop", "throws", "nulled", "nested") + (0 until 56).map { "p$it" }, calls)
        assertTrue(
            json,
            json.startsWith(
                "{\"map\":[[\"a\",\"t1\"],{\"nonStringKeys\":3},[\"drop\",{\"drop\":true}]," +
                    "[\"throws\",{\"drop\":true}],[\"nulled\",null],[\"nested\",[{\"unsupported\":true}]],[\"p0\",\"t0\"],",
            ),
        )
        assertTrue(json, json.endsWith("[\"p55\",\"t55\"]],\"omitted\":4}"))
    }

    @Test
    fun longStringsAreUnsupported() {
        assertEquals("{\"unsupported\":true}", value("x".repeat(1025)))
        assertEquals("\"${"x".repeat(1024)}\"", value("x".repeat(1024)))
    }

    @Test
    fun oneCollectionStopsAtTheItemBudgetWithOmitted() {
        val first256 = (0 until 256).joinToString(",")
        assertEquals("[$first256]", value((0 until 256).toList()))
        assertEquals("{\"list\":[$first256],\"omitted\":1}", value((0 until 300).toList()))
        assertEquals("{\"iterable\":[$first256],\"omitted\":1}", value((0 until 300).toSet()))
        val wide = LinkedHashMap<Any?, Any?>()
        wide[""] = 0
        (0 until 300).forEach { wide["k$it"] = it }
        val entries = (0 until 256).joinToString(",") { "[\"k$it\",$it]" }
        assertEquals("{\"map\":[{\"nonStringKeys\":1},$entries],\"omitted\":1}", value(wide))
    }

    @Test
    fun theItemBudgetIsSharedAcrossTheTreeInVisitOrder() {
        val parameters = linkedMapOf<String, Any?>(
            // 4 slots, depth first: the inner list, its 2 items, then "z"; "b" takes 250 and "c" the last 2.
            "a" to listOf(listOf(1, 2), "z"),
            "b" to (0 until 250).toList(),
            "c" to (0 until 10).toList(),
            "d" to emptyList<Any>(),
            "e" to linkedMapOf<Any?, Any?>(7 to "run", "k" to 1),
            "f" to setOf(1),
            "g" to "scalars still go",
        )

        assertEquals(
            "{\"map\":[[\"a\",[[1,2],\"z\"]],[\"b\",[${(0 until 250).joinToString(",")}]]," +
                "[\"c\",{\"list\":[0,1],\"omitted\":1}],[\"d\",[]]," +
                "[\"e\",{\"map\":[{\"nonStringKeys\":1}],\"omitted\":1}],[\"f\",{\"iterable\":[],\"omitted\":1}]," +
                "[\"g\",\"scalars still go\"]]}",
            parameters(ParameterPolicy.allowAll, parameters),
        )
    }

    @Test
    fun unreadValuesAreNotEncodedAndDoNotSpendTheBudget() {
        val reads = mutableListOf<Int>()
        val watched = object : AbstractList<Int>() {
            override val size get() = 300
            override fun get(index: Int): Int = index.also { reads += it }
        }
        val parameters = linkedMapOf<String, Any?>("hidden" to watched, "shown" to (0 until 3).toList())

        assertEquals(
            "{\"map\":[[\"hidden\",null],[\"shown\",[0,1,2]]]}",
            parameters(ParameterPolicy.allowList(setOf("shown")), parameters),
        )
        assertEquals("{\"map\":[[\"hidden\",null],[\"shown\",null]]}", parameters(ParameterPolicy.namesOnly, parameters))
        assertTrue(reads.isEmpty())
    }

    @Test
    fun aNetworkCallSendsItsFieldsRaw() {
        val json = EngineEvidenceEncoder.networkCall(
            NetworkCallInput(" get ", "/orders/123?x=1", 1_000, 251_000, null, NetworkOutcome.NetworkError, 0, "ignored"),
        )

        assertEquals(
            "{\"method\":\" get \",\"route\":\"/orders/123?x=1\",\"startMonoUs\":1000,\"endMonoUs\":251000," +
                "\"outcome\":\"network_error\",\"attemptCount\":0}",
            json,
        )
    }

    private fun body(status: Int?, body: Any?, outcome: NetworkOutcome = NetworkOutcome.Response): String =
        EngineEvidenceEncoder.networkCall(NetworkCallInput("GET", "/r", 0, 1, status, outcome, null, body))

    private fun bodyValue(body: Any): String {
        val json = body(500, body)
        return json.substring(json.indexOf("{\"value\":") + 9, json.length - 2)
    }

    @Test
    fun errorBodiesAreSentOnlyFromStatus400() {
        val unread = object : AbstractList<Any?>() {
            override val size: Int get() = error("a body below 400 is never read")
            override fun get(index: Int): Any? = error("a body below 400 is never read")
        }
        assertEquals(
            "{\"method\":\"GET\",\"route\":\"/r\",\"startMonoUs\":0,\"endMonoUs\":1,\"statusCode\":399,\"outcome\":\"response\"}",
            body(399, unread),
        )
        assertFalse(body(null, unread).contains("errorResponseBody"))
        assertTrue(body(400, "bad").endsWith(",\"statusCode\":400,\"outcome\":\"response\",\"errorResponseBody\":{\"value\":\"bad\"}}"))
        assertTrue(
            body(422, mapOf("code" to "invalid_project"), NetworkOutcome.Cancelled)
                .endsWith("\"outcome\":\"cancelled\",\"errorResponseBody\":{\"value\":{\"map\":[[\"code\",\"invalid_project\"]]}}}"),
        )
        assertFalse(body(500, byteArrayOf(1, 2)).contains("errorResponseBody"))
        assertFalse(body(500, null).contains("errorResponseBody"))
        assertEquals("{\"unsupported\":true}", bodyValue(intArrayOf(1)))
        assertEquals("42", bodyValue(42))
    }

    @Test
    fun aTextBodyIsCutPast4096BytesWithoutSplittingAPair() {
        assertEquals("\"${"a".repeat(4097)}\"", bodyValue("a".repeat(5000)))
        val pairAtCut = "a".repeat(4096) + "\uD83D\uDE00" + "tail"
        assertEquals("\"${"a".repeat(4096)}\uD83D\uDE00\"", bodyValue(pairAtCut))
        assertEquals("\"${"a".repeat(4097)}\"", bodyValue("a".repeat(4097)))
    }

    @Test
    fun errorBodyCollectionsSendTheirFirst128ItemsAndAreUnsupportedAtDepthSix() {
        assertEquals("{\"list\":[${(0 until 128).joinToString(",")}],\"omitted\":72}", bodyValue((0 until 200).toList()))
        assertEquals("[${(0 until 128).joinToString(",")}]", bodyValue((0 until 128).toList()))
        assertTrue(bodyValue((0 until 130).toSet()).endsWith(",127],\"omitted\":1}"))
        val wide = LinkedHashMap<Any?, Any?>()
        wide[1] = "number key"
        (0 until 200).forEach { wide["k$it"] = it }
        val map = bodyValue(wide)
        assertTrue(map, map.startsWith("{\"map\":[{\"nonStringKeys\":1},[\"k0\",0],"))
        assertTrue(map, map.endsWith("[\"k126\",126]],\"omitted\":73}"))

        // Root depth 0: collections at depth 6 are unsupported, scalars there are still sent.
        assertEquals("[[[[[[\"leaf\",{\"unsupported\":true}]]]]]]", bodyValue(listOf(listOf(listOf(listOf(listOf(listOf("leaf", listOf(1)))))))))
        assertEquals("{\"map\":[[\"k\",\"${"k".repeat(4097)}\"],[\"${"y".repeat(4097)}\",1]]}", bodyValue(linkedMapOf("k" to "k".repeat(5000), "y".repeat(5000) to 1)))

        val cyclic = mutableListOf<Any?>()
        cyclic.add(cyclic)
        assertEquals("[{\"ref\":1}]", bodyValue(cyclic))
    }

    @Test
    fun nonFiniteDoublesUnsupportedValuesAndIterablesAreNotNodes() {
        val nan = "{\"double\":\"NaN\"}"
        val row = List(128) { nan }.joinToString(",", "[", "]")
        assertEquals(List(40) { row }.joinToString(",", "[", "]"), bodyValue(List(40) { List(128) { Double.NaN } }))
        val unsupported = List(128) { "{\"unsupported\":true}" }.joinToString(",", "[", "]")
        assertEquals(List(40) { unsupported }.joinToString(",", "[", "]"), bodyValue(List(40) { List(128) { 'c' } }))
    }

    @Test
    fun anErrorBodyStopsAfter4097Nodes() {
        val grid = List(128) { row -> List(128) { column -> row * 128 + column } }

        // The root (1) and 31 full rows (31 * 129) are 4000 nodes; the 32nd row
        // and its first 96 items reach 4097, and every open collection closes.
        val full = (0 until 31).joinToString(",") { row -> grid[row].joinToString(",", "[", "]") }
        val last = grid[31].take(96).joinToString(",", "[", "]")
        assertEquals("[$full,$last]", bodyValue(grid))
    }
}
