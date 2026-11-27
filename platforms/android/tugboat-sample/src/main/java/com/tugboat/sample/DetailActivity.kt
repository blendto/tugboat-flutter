package com.tugboat.sample

import android.app.Activity
import android.os.Bundle
import android.widget.Button
import com.tugboat.android.tugboatTag

/** The second screen: its own route (`route_change`), text and an image to mask. */
class DetailActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_detail)
        applySystemBarInsets(findViewById(R.id.detail_root))
        findViewById<Button>(R.id.back).apply {
            tugboatTag = "details_back"
            setOnClickListener { finish() }
        }
    }
}
