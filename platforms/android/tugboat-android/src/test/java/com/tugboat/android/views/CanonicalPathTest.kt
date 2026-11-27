package com.tugboat.android.views

import android.content.Context
import android.view.View
import android.view.ViewGroup
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.tugboat.android.views.identity.AndroidResourceNames
import com.tugboat.android.views.identity.CanonicalPathBuilder
import com.tugboat.android.views.identity.ResourceNames
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Canonical paths on fixture layouts (design note 6.1). */
@RunWith(RobolectricTestRunner::class)
class CanonicalPathTest {
    private val names = AndroidResourceNames(context.resources)
    private val paths = CanonicalPathBuilder(names)

    @Test
    fun resourceNamesAreUsableInAnUnobfuscatedBuild() {
        assertTrue(names.enabled)
    }

    @Test
    fun nestedLayoutsCollapseAndCustomSubclassesMapToPlatformTokens() {
        val target = CheckoutButton(context)
        val root = frame(column(MyRow(context).apply { addView(column(target)) }))
        layOut(root)
        assertEquals("Button#0", paths.build(root, target)!!.value)
    }

    @Test
    fun ordinalsCountSameTokenSiblingsAfterFiltering() {
        val gone = Button(context).apply { visibility = View.GONE }
        val first = Button(context)
        val label = TextView(context)
        val third = Button(context)
        val root = frame(column(gone, first, label, column(third)))
        layOut(root)
        assertEquals("Button#0", paths.build(root, first)!!.value)
        assertEquals("TextView#0", paths.build(root, label)!!.value)
        // The hidden button and the collapsed column do not count.
        assertEquals("Button#1", paths.build(root, third)!!.value)
    }

    @Test
    fun keptAncestorsScopeOrdinalsAndIdsNameTokens() {
        val target = Button(context)
        val card = column(Button(context), target).apply { isClickable = true }
        val named = Button(context).apply { id = android.R.id.button1 }
        val root = frame(column(card, named))
        layOut(root)
        assertEquals("LinearLayout#0/Button#1", paths.build(root, target)!!.value)
        assertEquals("Button#button1", paths.build(root, named)!!.value)
    }

    @Test
    fun repeatedIdsGetAnOrdinal() {
        val a = Button(context).apply { id = android.R.id.button1 }
        val b = Button(context).apply { id = android.R.id.button1 }
        val root = frame(column(a, b))
        layOut(root)
        assertEquals("Button#button1", paths.build(root, a)!!.value)
        assertEquals("Button#button1#1", paths.build(root, b)!!.value)
    }

    @Test
    fun recyclerViewChildrenUseAdapterPositions() {
        val list = RecyclerView(context).apply {
            id = android.R.id.list
            layoutManager = LinearLayoutManager(context)
            adapter = RowAdapter(20)
        }
        val root = frame(list)
        layOut(root)
        val row = list.getChildAt(2) as ViewGroup
        val label = row.getChildAt(0)
        assertEquals("ViewGroup#list/[item:2]/LinearLayout#0", paths.build(root, row)!!.value)
        assertEquals("ViewGroup#list/[item:2]/LinearLayout#0/TextView#0", paths.build(root, label)!!.value)
        assertTrue(paths.build(root, row)!!.inListItem)
    }

    @Test
    fun absListViewChildrenUseFirstVisiblePositionPlusIndex() {
        val list = ListView(context).apply {
            adapter = ArrayAdapter(context, android.R.layout.simple_list_item_1, (0 until 50).map { "row $it" })
        }
        val root = frame(list)
        layOut(root)
        list.setSelection(10)
        layOut(root)
        val child = list.getChildAt(1)
        val index = list.firstVisiblePosition + 1
        assertEquals("ListView#0/[item:$index]/TextView#text1", paths.build(root, child)!!.value)
    }

    @Test
    fun obfuscatedResourceNamesDropIds() {
        val target = Button(context).apply { id = android.R.id.button1 }
        val root = frame(column(target))
        layOut(root)
        val obfuscated = CanonicalPathBuilder(ResourceNames { null })
        assertEquals("Button#0", obfuscated.build(root, target)!!.value)
    }

    @Test
    fun aViewOutsideTheRootHasNoPath() {
        val root = frame(column())
        layOut(root)
        assertNull(paths.build(root, Button(context)))
    }

    private fun frame(vararg children: View) = FrameLayout(context).apply { children.forEach(::addView) }

    private fun column(vararg children: View) =
        LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            children.forEach { addView(it, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 100)) }
        }

    class CheckoutButton(context: Context) : Button(context)

    class MyRow(context: Context) : LinearLayout(context)
}

/** Rows: a clickable `LinearLayout` holding one `TextView`. */
internal class RowAdapter(private val count: Int) : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
        val row = LinearLayout(parent.context).apply {
            isClickable = true
            addView(TextView(parent.context).apply { text = "row" })
            layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 100)
        }
        return object : RecyclerView.ViewHolder(row) {}
    }

    override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) = Unit

    override fun getItemCount(): Int = count
}
