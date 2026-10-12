package com.tugboat.sample

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.tugboat.android.compose.tugboatTag

/**
 * Compose on the default masking (`ComposeMasking.WholeHost`, installed by
 * [SampleApplication]): the whole Compose host is masked in every frame,
 * while taps, scrolls, and focus are still read from the semantics tree
 * (`targetAnchor.toolkit = "compose"`).
 */
class ComposeWholeHostActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { MaterialTheme { WholeHostScreen() } }
    }
}

@androidx.compose.runtime.Composable
private fun WholeHostScreen() {
    var taps by rememberSaveable { mutableIntStateOf(0) }
    var note by rememberSaveable { mutableStateOf("") }
    Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.compose_whole_host_title), style = MaterialTheme.typography.titleLarge)
        Button(onClick = { taps++ }, modifier = Modifier.tugboatTag("compose_primary")) {
            Text(stringResource(R.string.tap_count, taps))
        }
        OutlinedTextField(
            value = note,
            onValueChange = { note = it },
            label = { Text(stringResource(R.string.note_hint)) },
            modifier = Modifier.fillMaxWidth(),
        )
        LazyColumn(Modifier.fillMaxWidth().weight(1f)) {
            items(ROWS) { index -> Text(stringResource(R.string.row, index + 1), Modifier.padding(vertical = 16.dp)) }
        }
    }
}

private const val ROWS = 40
