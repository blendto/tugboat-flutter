package com.tugboat.android.views

import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.tugboat.android.views.identity.AnchorResolver
import com.tugboat.android.views.identity.AndroidResourceNames
import com.tugboat.android.views.identity.Confidence
import com.tugboat.android.views.identity.IdentityHash
import com.tugboat.android.views.identity.RouteKey
import com.tugboat.android.views.identity.ViewTags
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Anchors, aliases, confidence, and tap resolution (design note 6, 6.1). */
@RunWith(RobolectricTestRunner::class)
class AnchorResolverTest {
    private val button = Button(context)
    private val label = TextView(context)
    private val root = FrameLayout(context).apply {
        addView(
            LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                addView(label, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 200))
                addView(button, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 200))
            },
        )
    }
    private val anchors = anchorResolver(root, routeKey = "com.example.HomeActivity")

    @Test
    fun anchorJsonCarriesTheFingerprintOfRouteKeyAndPathAndTheViewToolkit() {
        layOut(root)
        val anchor = anchors.anchorFor(button, root)!!
        val fingerprint = IdentityHash.fingerprint(mapOf("routeKey" to "com.example.HomeActivity", "path" to "Button#0"))
        val expected = JSONObject()
            .put("schemaVersion", 6)
            .put("widgetType", "Button")
            .put("role", "button")
            .put("fingerprint", fingerprint)
            .put("fingerprintConfidence", "low")
            .put("fingerprintParts", JSONObject().put("schemaVersion", "6").put("routeKey", "com.example.HomeActivity"))
            .put("canonicalPath", "Button#0")
            .put("relativePosition", "top")
            .put("enabled", true)
            .put("actions", JSONArray(listOf("tap")))
            .put("toolkit", "view")
        assertEquals(expected.toString(), anchor.toJson().toString())
    }

    @Test
    fun tugboatTagIsAHighConfidenceAliasTransparentToTheFingerprint() {
        layOut(root)
        val untagged = anchors.anchorFor(button, root)!!
        ViewTags.setAlias(button, "pay-button")
        val tagged = anchors.anchorFor(button, root)!!

        assertEquals(untagged.fingerprint, tagged.fingerprint)
        assertEquals(Confidence.High, tagged.confidence)
        assertEquals(
            IdentityHash.fingerprint(mapOf("routeKey" to "com.example.HomeActivity", "tag" to "pay-button")),
            tagged.tagFingerprint,
        )
        assertEquals("pay-button", tagged.toJson().getJSONObject("fingerprintParts").getString("tag"))
    }

    @Test
    fun aUniqueResourceIdIsAnAliasAndARepeatedOneIsOnlyStructure() {
        button.id = android.R.id.button1
        layOut(root)
        val unique = anchors.anchorFor(button, root)!!
        assertEquals("button1", unique.tag)
        assertEquals(Confidence.High, unique.confidence)

        label.id = android.R.id.button1
        val repeated = anchors.anchorFor(button, root)!!
        assertNull(repeated.tag)
        assertEquals(Confidence.Medium, repeated.confidence)
    }

    @Test
    fun confidenceIsTheFloorOfRouteAndPath() {
        layOut(root)
        ViewTags.setAlias(button, "pay")
        val lowRoute = AnchorResolver(AndroidResourceNames(context.resources)) { RouteKey("com.example.F", Confidence.Low, root) }
        assertEquals(Confidence.Low, lowRoute.anchorFor(button, root)!!.confidence)
    }

    @Test
    fun visibleTextNeverEntersIdentity() {
        layOut(root)
        button.text = "Pay 10 EUR"
        val first = anchors.anchorFor(button, root)!!
        button.text = "Payer 10 EUR"
        button.contentDescription = "pay"
        assertEquals(first, anchors.anchorFor(button, root))
    }

    @Test
    fun tapOnAChildResolvesToItsActionableAncestor() {
        val row = LinearLayout(context).apply {
            isClickable = true
            addView(TextView(context), LinearLayout.LayoutParams(400, 100))
        }
        val tapRoot = FrameLayout(context).apply { addView(row, FrameLayout.LayoutParams(720, 100)) }
        layOut(tapRoot)
        val evidence = anchorResolver(tapRoot).tapEvidence(tapRoot, 50f, 50f)
        assertEquals("LinearLayout#0", evidence.anchor!!.canonicalPath)
        assertEquals("button", evidence.anchor!!.role)
    }

    @Test
    fun tapInAListResolvesTheItemRow() {
        val list = RecyclerView(context).apply {
            layoutManager = LinearLayoutManager(context)
            adapter = RowAdapter(20)
        }
        val listRoot = FrameLayout(context).apply { addView(list) }
        layOut(listRoot)
        val evidence = anchorResolver(listRoot).tapEvidence(listRoot, 10f, 350f)
        assertEquals("ViewGroup#0/[item:3]/LinearLayout#0", evidence.anchor!!.canonicalPath)
        assertEquals(Confidence.Medium, evidence.anchor!!.confidence)
    }

    @Test
    fun theTopmostChildWinsAndAnOverlayThatDoesNotConsumeFallsThrough() {
        val under = Button(context)
        val overlay = View(context)
        val stack = FrameLayout(context).apply {
            addView(under, FrameLayout.LayoutParams(720, 300))
            addView(overlay, FrameLayout.LayoutParams(720, 300))
        }
        layOut(stack)
        assertEquals("Button#0", anchorResolver(stack).tapEvidence(stack, 10f, 10f).anchor!!.canonicalPath)

        overlay.isClickable = true
        overlay.id = android.R.id.icon
        assertEquals("View#icon", anchorResolver(stack).tapEvidence(stack, 10f, 10f).anchor!!.canonicalPath)
    }

    @Test
    fun aTapOutsideTheWindowHasNoTarget() {
        layOut(root)
        val evidence = anchors.tapEvidence(root, -5f, 10f)
        assertNull(evidence.anchor)
        assertEquals("""{"failureReason":"no_target_at_point"}""", evidence.toJson().toString())
    }

    @Test
    fun editTextIsATextFieldWithInputAction() {
        val field = EditText(context)
        val fieldRoot = FrameLayout(context).apply { addView(field, FrameLayout.LayoutParams(720, 100)) }
        layOut(fieldRoot)
        val anchor = anchorResolver(fieldRoot).anchorFor(field, fieldRoot)!!
        assertEquals("textField", anchor.role)
        assertFalse(anchor.actions.isEmpty())
        assertEquals("EditText#0", anchor.canonicalPath)
    }
}
