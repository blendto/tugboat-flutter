package com.tugboat.sample

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.tugboat.android.Tugboat
import com.tugboat.android.compose.ComposeMasking
import com.tugboat.android.compose.TugboatCompose
import com.tugboat.android.compose.tugboatTag

/**
 * Compose opted into `ComposeMasking.SemanticsBestEffort`: only what the
 * semantics tree describes is masked (text, editable text, described
 * images). This screen draws nothing without semantics: its one image has a
 * content description, and nothing is drawn on a `Canvas`.
 *
 * Masking is process-wide (`TugboatCompose.install`), so this screen opts in
 * while it is resumed and restores the default when it pauses. Its
 * Navigation Compose destinations (`rows`, `row/{index}`) are route keys
 * through `Tugboat.trackNavigation`.
 */
class ComposeSemanticsActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            val navController = rememberNavController()
            androidx.compose.runtime.LaunchedEffect(navController) { Tugboat.trackNavigation(navController) }
            MaterialTheme { SemanticsNavHost(navController) }
        }
    }

    override fun onResume() {
        super.onResume()
        TugboatCompose.install(composeMasking = ComposeMasking.SemanticsBestEffort)
    }

    override fun onPause() {
        TugboatCompose.install(composeMasking = ComposeMasking.WholeHost)
        super.onPause()
    }
}

@Composable
private fun SemanticsNavHost(navController: NavHostController) {
    NavHost(navController, startDestination = "rows") {
        composable("rows") { RowsScreen(onRow = { navController.navigate("row/$it") }) }
        composable("row/{index}") { entry ->
            RowScreen(entry.arguments?.getString("index").orEmpty(), onBack = { navController.popBackStack() })
        }
    }
}

@Composable
private fun RowsScreen(onRow: (Int) -> Unit) {
    var note by rememberSaveable { mutableStateOf("") }
    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.compose_semantics_title), style = MaterialTheme.typography.titleLarge)
        OutlinedTextField(
            value = note,
            onValueChange = { note = it },
            label = { Text(stringResource(R.string.note_hint)) },
            modifier = Modifier.fillMaxWidth(),
        )
        LazyColumn(Modifier.fillMaxWidth().weight(1f)) {
            items(ROWS) { index ->
                Text(
                    stringResource(R.string.row, index + 1),
                    Modifier.fillMaxWidth().clickable { onRow(index + 1) }.padding(vertical = 16.dp),
                )
            }
        }
    }
}

@Composable
private fun RowScreen(index: String, onBack: () -> Unit) {
    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.compose_row_title, index), style = MaterialTheme.typography.titleLarge)
        Image(
            painter = painterResource(android.R.drawable.ic_menu_gallery),
            contentDescription = stringResource(R.string.compose_image_description),
            modifier = Modifier.size(96.dp),
        )
        Button(onClick = onBack, modifier = Modifier.tugboatTag("compose_back")) { Text(stringResource(R.string.back)) }
    }
}

private const val ROWS = 40
