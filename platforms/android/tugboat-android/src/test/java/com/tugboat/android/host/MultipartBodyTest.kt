package com.tugboat.android.host

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import java.io.File

/**
 * The multipart layout Dart's `http.MultipartRequest` writes, pinned by
 * `conformance/host/multipart-request.golden`, which the Apple host's
 * `MultipartBodyTests` reads too.
 */
class MultipartBodyTest {
    private fun golden(): ByteArray {
        val dir = System.getProperty("tugboat.hostFixtures") ?: "../../conformance/host"
        return File(dir, "multipart-request.golden").readBytes()
    }

    @Test
    fun writesTheSharedGoldenBytes() {
        val body = MultipartBody(
            fields = listOf("sessionId" to "s-1", "frameNos" to "1,2", "label" to "café", "a\"b\r\nc" to "v"),
            files = listOf(
                MultipartBody.File("files", "1.jpg", "image/jpeg", "JPEG".toByteArray()),
                MultipartBody.File("files", "2.jpg", "image/jpeg", byteArrayOf(-1, -40, 13, 10, -1, -39)),
            ),
            boundary = "b",
        )

        assertEquals("multipart/form-data; boundary=b", body.contentType)
        assertArrayEquals(golden(), body.toByteArray())
    }

    @Test
    fun nameEncodingCoversEveryNewlineForm() {
        val body = MultipartBody(listOf("a\"b\r\nc\rd\ne" to "v"), emptyList(), boundary = "b")
        assertEquals(
            "--b\r\ncontent-disposition: form-data; name=\"a%22b%0D%0Ac%0D%0Ad%0D%0Ae\"\r\n\r\nv\r\n--b--\r\n",
            body.toByteArray().toString(Charsets.UTF_8),
        )
    }

    @Test
    fun boundariesAreRandom() {
        val a = MultipartBody(emptyList(), emptyList()).boundary
        val b = MultipartBody(emptyList(), emptyList()).boundary
        assertEquals(49, a.length)
        assertNotEquals(a, b)
    }
}
