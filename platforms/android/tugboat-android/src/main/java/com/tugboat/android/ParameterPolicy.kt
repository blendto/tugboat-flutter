package com.tugboat.android

/**
 * Which parameter values of an [EventHook.record] are kept. The same four
 * policies as Flutter's `TugboatParameterPolicy`:
 *
 * - [allowAll] (the default): every JSON value, within the engine's limits.
 *   This can keep feedback text, search terms, ids, and other user content.
 * - [namesOnly]: the parameter keys, never a value.
 * - [allowList]: values only for the named keys; the other keys are kept
 *   without their values.
 * - [transform]: your function returns the value to keep for each key, or
 *   [DROP] to keep the key without its value.
 *
 * The session engine applies the policy and its limits before the event is
 * recorded; nothing leaves the process before that.
 */
class ParameterPolicy private constructor(
    internal val mode: Mode,
    /** For [Mode.AllowList]: the keys whose values are kept. */
    internal val allowedKeys: Set<String> = emptySet(),
    internal val transform: ParameterTransform? = null,
) {
    internal enum class Mode { NamesOnly, AllowList, Transform, AllowAll }

    override fun toString(): String = "ParameterPolicy(${mode.name})"

    companion object {
        /** Keys only: no value is kept. */
        @JvmField
        val namesOnly = ParameterPolicy(Mode.NamesOnly)

        /** Every JSON value, within the engine's limits. The default. */
        @JvmField
        val allowAll = ParameterPolicy(Mode.AllowAll)

        /**
         * Returned from a [transform] function: keep the key, drop its value.
         * Returning `null` keeps a `null` value instead.
         */
        @JvmField
        val DROP: Any = Drop

        /** Values only for [keys]; the set is copied. */
        @JvmStatic
        fun allowList(keys: Set<String>) = ParameterPolicy(Mode.AllowList, allowedKeys = keys.toSet())

        /**
         * [transform] runs on the thread that calls [EventHook.record], once
         * per top-level key, before `record` returns. It returns the value to
         * keep or [DROP]. A function that throws drops that key's value.
         */
        @JvmStatic
        fun transform(transform: ParameterTransform) = ParameterPolicy(Mode.Transform, transform = transform)
    }

    private object Drop {
        override fun toString(): String = "ParameterPolicy.DROP"
    }
}

/** A [ParameterPolicy.transform] function. */
fun interface ParameterTransform {
    /** The value to keep for [key], or [ParameterPolicy.DROP]. */
    fun apply(key: String, value: Any?): Any?
}
