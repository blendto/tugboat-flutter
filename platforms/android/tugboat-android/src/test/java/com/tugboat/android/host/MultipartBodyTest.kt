package com.tugboat.android.host

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class MultipartBodyTest {
    @Test
    fun writesTheSameBytesAsDartMultipartRequest() {
        val body = MultipartBody(
            fields = listOf("sessionId" to "s-1", "frameNos" to "7"),
            files = listOf(MultipartBody.File("files", "7.jpg", "image/jpeg", "JPEG".toByteArray())),
            boundary = "b",
        )

        assertEquals("multipart/form-data; boundary=b", body.contentType)
        assertEquals(
            "--b\r\ncontent-disposition: form-data; name=\"sessionId\"\r\n\r\ns-1\r\n" +
                "--b\r\ncontent-disposition: form-data; name=\"frameNos\"\r\n\r\n7\r\n" +
                "--b\r\ncontent-type: image/jpeg\r\n" +
                "content-disposition: form-data; name=\"files\"; filename=\"7.jpg\"\r\n\r\nJPEG\r\n" +
                "--b--\r\n",
            body.toByteArray().toString(Charsets.UTF_8),
        )
    }

    @Test
    fun nonAsciiFieldsDeclareUtf8LikeDart() {
        val body = MultipartBody(listOf("label" to "café"), emptyList(), boundary = "b")
        assertEquals(
            "--b\r\ncontent-disposition: form-data; name=\"label\"\r\n" +
                "content-type: text/plain; charset=utf-8\r\ncontent-transfer-encoding: binary\r\n\r\n" +
                "café\r\n--b--\r\n",
            body.toByteArray().toString(Charsets.UTF_8),
        )
    }

    @Test
    fun namesAreBrowserEncoded() {
        val body = MultipartBody(listOf("a\"b\r\nc" to "v"), emptyList(), boundary = "b")
        assertEquals(
            "--b\r\ncontent-disposition: form-data; name=\"a%22b%0D%0Ac\"\r\n\r\nv\r\n--b--\r\n",
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
