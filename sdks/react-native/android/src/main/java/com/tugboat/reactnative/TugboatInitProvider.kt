package com.tugboat.reactnative

import android.app.Application
import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.util.Log
import android.view.View
import com.tugboat.android.adapter.TugboatAdapterApi
import com.tugboat.android.adapter.TugboatAdapters

/**
 * Runs before any activity exists: the SDK then knows the first activity when
 * JavaScript calls `Tugboat.start` later. Does nothing else, and nothing here
 * throws. If `Tugboat.start` never runs, it only observes activities and fragments.
 */
@OptIn(TugboatAdapterApi::class)
class TugboatInitProvider : ContentProvider() {
    override fun onCreate(): Boolean {
        try {
            val application = context?.applicationContext as? Application ?: return true
            TugboatAdapters.install(application)
            // testID is the view's name: path token, alias, `tag`.
            TugboatAdapters.setViewNameProvider(::testId)
            // react-native-screens hosts each screen in a fragment; JavaScript names the screen.
            TugboatAdapters.setFragmentFilter { it.startsWith("com.swmansion.rnscreens.") }
        } catch (t: Throwable) {
            Log.w("TugboatRN", "early install failed", t)
        }
        return true
    }

    private fun testId(view: View): String? =
        (view.getTag(com.facebook.react.R.id.react_test_id) as? String)?.takeIf { it.isNotEmpty() }

    override fun query(uri: Uri, projection: Array<String>?, selection: String?, selectionArgs: Array<String>?, sortOrder: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<String>?) = 0
}
