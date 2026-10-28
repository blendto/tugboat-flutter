package com.tugboat.sample

import android.app.Dialog
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.compose.setContent
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog as ComposeDialog
import androidx.fragment.app.DialogFragment
import com.tugboat.android.compose.tugboatTag
import com.tugboat.android.tugboatTag
import androidx.compose.material3.Button as ComposeButton

/**
 * Dialog windows for the device pass (W6b-1): an AppCompat `AlertDialog`,
 * a `DialogFragment` (tag `sample_dialog`), a Compose `Dialog` with a text
 * field, and a material3 `ModalBottomSheet`. Each is a `ComponentDialog`, so
 * its taps, keys and focus are recorded (the `DialogFragment` on every API
 * level, the others on API 29+). The framework dialog on `MainActivity`
 * stays the documented gap.
 */
class DialogsActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { Surface { DialogsScreen() } }
    }

    @OptIn(ExperimentalMaterial3Api::class)
    @Composable
    private fun DialogsScreen() {
        var composeDialog by rememberSaveable { mutableStateOf(false) }
        var sheet by rememberSaveable { mutableStateOf(false) }
        var note by rememberSaveable { mutableStateOf("") }
        Column(Modifier.padding(16.dp)) {
            ComposeButton(onClick = ::showAppCompatDialog, modifier = Modifier.tugboatTag("open_appcompat_dialog")) {
                Text(stringResource(R.string.open_appcompat_dialog))
            }
            ComposeButton(onClick = ::showDialogFragment, modifier = Modifier.tugboatTag("open_dialog_fragment")) {
                Text(stringResource(R.string.open_dialog_fragment))
            }
            ComposeButton(onClick = { composeDialog = true }, modifier = Modifier.tugboatTag("open_compose_dialog")) {
                Text(stringResource(R.string.open_compose_dialog))
            }
            ComposeButton(onClick = { sheet = true }, modifier = Modifier.tugboatTag("open_bottom_sheet")) {
                Text(stringResource(R.string.open_bottom_sheet))
            }
        }
        if (composeDialog) {
            ComposeDialog(onDismissRequest = { composeDialog = false }) {
                Surface {
                    Column(Modifier.padding(16.dp)) {
                        TextField(value = note, onValueChange = { note = it }, modifier = Modifier.tugboatTag("compose_dialog_note"))
                        ComposeButton(onClick = { composeDialog = false }, modifier = Modifier.tugboatTag("compose_dialog_ok")) {
                            Text(stringResource(R.string.ok))
                        }
                    }
                }
            }
        }
        if (sheet) {
            ModalBottomSheet(onDismissRequest = { sheet = false }) {
                ComposeButton(
                    onClick = { sheet = false },
                    modifier = Modifier.padding(16.dp).tugboatTag("bottom_sheet_ok"),
                ) {
                    Text(stringResource(R.string.ok))
                }
            }
        }
    }

    private fun showAppCompatDialog() {
        AlertDialog.Builder(this)
            .setTitle(R.string.appcompat_dialog_title)
            .setMessage(R.string.appcompat_dialog_message)
            .setPositiveButton(R.string.ok, null)
            .show()
    }

    private fun showDialogFragment() {
        SampleDialogFragment().show(supportFragmentManager, "sample_dialog")
    }

    /** A dialog fragment with its own view, in the default `ComponentDialog`. */
    class SampleDialogFragment : DialogFragment() {
        override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View {
            val context = inflater.context
            return LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(48, 48, 48, 48)
                addView(TextView(context).apply { setText(R.string.dialog_fragment_message) })
                addView(
                    Button(context).apply {
                        setText(R.string.ok)
                        tugboatTag = "dialog_fragment_ok"
                        setOnClickListener { dismiss() }
                    },
                )
            }
        }

        override fun onCreateDialog(savedInstanceState: Bundle?): Dialog =
            super.onCreateDialog(savedInstanceState).apply { setTitle(R.string.dialog_fragment_title) }
    }
}
