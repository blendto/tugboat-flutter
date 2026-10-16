package com.tugboat.sample

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Button
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.tugboat.android.ParameterPolicy
import com.tugboat.android.Tugboat
import com.tugboat.android.tugboatTag

/**
 * The Views screen of the device-test script (README): a tagged button, a
 * swipe area, a text field, a list, a dialog, and the ways to the second
 * screen and the two Compose screens.
 */
class MainActivity : Activity() {
    private var taps = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        applySystemBarInsets(findViewById(R.id.main_root))
        taps = savedInstanceState?.getInt(KEY_TAPS) ?: 0

        val count = findViewById<TextView>(R.id.tap_count)
        count.text = getString(R.string.tap_count, taps)
        findViewById<Button>(R.id.primary_action).apply {
            tugboatTag = "primary_action"
            setOnClickListener {
                count.text = getString(R.string.tap_count, ++taps)
                // A coded event, as an app would forward its analytics events.
                events.record("PRIMARY_TAPPED", mapOf("taps" to taps, "screen" to "main"))
            }
        }
        findViewById<Button>(R.id.open_details).apply {
            tugboatTag = "open_details"
            setOnClickListener {
                loadDetails()
                startActivity(Intent(this@MainActivity, DetailActivity::class.java))
            }
        }
        findViewById<Button>(R.id.show_dialog).setOnClickListener { showDialog() }
        findViewById<Button>(R.id.open_compose).setOnClickListener {
            startActivity(Intent(this, ComposeWholeHostActivity::class.java))
        }
        findViewById<Button>(R.id.open_compose_semantics).setOnClickListener {
            startActivity(Intent(this, ComposeSemanticsActivity::class.java))
        }
        findViewById<Button>(R.id.stop_tugboat).setOnClickListener {
            Tugboat.stop()
            it.isEnabled = false
            (it as Button).setText(R.string.tugboat_stopped)
        }
        findViewById<RecyclerView>(R.id.list).apply {
            layoutManager = LinearLayoutManager(this@MainActivity)
            adapter = RowsAdapter(ROWS)
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putInt(KEY_TAPS, taps)
    }

    /**
     * A manual network call and a real one. The manual call makes no
     * request: it stands in for one that answers after 200 ms (a real app
     * finishes the call where its HTTP client reports the status or the
     * failure). The real one goes through [SampleHttp]'s OkHttp client,
     * which `TugboatOkHttpInterceptor` records.
     */
    private fun loadDetails() {
        val call = Tugboat.beginNetworkCall(method = "GET", route = "/details/42")
        Handler(Looper.getMainLooper()).postDelayed({ call.complete(statusCode = 200) }, 200)
        SampleHttp.loadOrder()
    }

    private fun showDialog() {
        AlertDialog.Builder(this)
            .setTitle(R.string.dialog_title)
            .setMessage(R.string.dialog_message)
            .setPositiveButton(R.string.ok, null)
            .show()
    }

    private companion object {
        const val KEY_TAPS = "taps"
        const val ROWS = 50

        // Only `taps` keeps its value; `screen` is recorded as a key only.
        val events = Tugboat.eventHook(source = "sample", parameterPolicy = ParameterPolicy.allowList(setOf("taps")))
    }
}
