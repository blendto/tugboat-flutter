package com.tugboat.android.compose.semantics

import androidx.compose.ui.platform.ViewRootForTest

/**
 * The tested Compose UI range (README "Compose versions"). The version is
 * read once from the `META-INF/androidx.compose.ui_ui.version` resource every
 * Compose UI release ships (Android Studio's Layout Inspector reads the same
 * file). Missing (an app that strips the `.version` files from `META-INF`), unreadable, or
 * outside the range means unverified: hosts are masked whole and the
 * `SemanticsBestEffort` opt-in is ignored.
 */
internal object ComposeUiVersion {
    /** Inclusive floor, exclusive ceiling. */
    val TESTED_FLOOR = listOf(1, 7, 0)
    val TESTED_CEILING = listOf(1, 9, 0)

    private const val RESOURCE = "META-INF/androidx.compose.ui_ui.version"

    val current: String? by lazy { read() }

    val verified: Boolean by lazy { isTested(current) }

    /** True when [version] (`1.8.3`, `1.9.0-beta01`) is inside the tested range. */
    fun isTested(version: String?): Boolean {
        val parts = version?.substringBefore('-')?.split('.')?.map { it.toIntOrNull() ?: return false } ?: return false
        if (parts.size != 3) return false
        return compare(parts, TESTED_FLOOR) >= 0 && compare(parts, TESTED_CEILING) < 0
    }

    private fun compare(a: List<Int>, b: List<Int>): Int =
        a.zip(b).map { (x, y) -> x.compareTo(y) }.firstOrNull { it != 0 } ?: 0

    private fun read(): String? =
        runCatching {
            ViewRootForTest::class.java.classLoader
                ?.getResourceAsStream(RESOURCE)
                ?.use { it.readBytes().decodeToString().trim() }
        }.getOrNull()
}
