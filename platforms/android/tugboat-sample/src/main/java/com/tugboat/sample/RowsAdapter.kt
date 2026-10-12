package com.tugboat.sample

import android.view.LayoutInflater
import android.view.ViewGroup
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView

/** [count] plain text rows: list items get `[item:index]` identity and are masked as text. */
class RowsAdapter(private val count: Int) : RecyclerView.Adapter<RowsAdapter.Row>() {
    class Row(val text: TextView) : RecyclerView.ViewHolder(text)

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): Row =
        Row(LayoutInflater.from(parent.context).inflate(R.layout.list_row, parent, false) as TextView)

    override fun onBindViewHolder(holder: Row, position: Int) {
        holder.text.text = holder.text.context.getString(R.string.row, position + 1)
    }

    override fun getItemCount(): Int = count
}
