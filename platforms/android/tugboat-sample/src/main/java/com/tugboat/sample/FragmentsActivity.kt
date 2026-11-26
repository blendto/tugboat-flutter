package com.tugboat.sample

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.FragmentContainerView
import com.tugboat.android.compose.tugboatTag
import com.tugboat.android.tugboatTag

/**
 * Fragments without Jetpack Navigation: a `FragmentContainerView` below two
 * buttons that replace its fragment. Route keys are the fragment tags
 * (`views_home`, `compose_home`); scene inventories take the shown fragment's
 * route. The Views fragment's root is clickable (it stops clicks reaching
 * what is below), so its own canonical path is empty; the Compose fragment's
 * view is a `ComposeView`.
 */
class FragmentsActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(button(R.string.show_views_fragment, "show_views_fragment") { show(ViewsHomeFragment(), "views_home") })
        root.addView(button(R.string.show_compose_fragment, "show_compose_fragment") { show(ComposeHomeFragment(), "compose_home") })
        root.addView(
            FragmentContainerView(this).apply { id = R.id.fragment_container },
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f),
        )
        setContentView(root)
        applySystemBarInsets(root)
        if (savedInstanceState == null) show(ViewsHomeFragment(), "views_home")
    }

    private fun button(text: Int, tag: String, onClick: () -> Unit) =
        Button(this).apply {
            setText(text)
            tugboatTag = tag
            setOnClickListener { onClick() }
        }

    private fun show(fragment: Fragment, tag: String) {
        supportFragmentManager.beginTransaction().replace(R.id.fragment_container, fragment, tag).commit()
    }

    class ViewsHomeFragment : Fragment() {
        override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View {
            val context = inflater.context
            val column = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
            column.addView(TextView(context).apply { setText(R.string.fragment_title) })
            column.addView(
                Button(context).apply {
                    setText(R.string.fragment_action)
                    tugboatTag = "fragment_action"
                },
            )
            return FrameLayout(context).apply {
                isClickable = true
                addView(column)
            }
        }
    }

    class ComposeHomeFragment : Fragment() {
        override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View =
            ComposeView(inflater.context).apply {
                setContent {
                    Column(Modifier.padding(16.dp)) {
                        Button(onClick = {}, modifier = Modifier.tugboatTag("compose_fragment_action")) {
                            Text(stringResource(R.string.compose_fragment_action))
                        }
                    }
                }
            }
    }
}
