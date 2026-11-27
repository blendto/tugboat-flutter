package com.tugboat.android.okhttp;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.mockwebserver.MockResponse;
import okhttp3.mockwebserver.MockWebServer;
import okio.Buffer;
import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

/**
 * The {@code conformance/evidence/network_call/*json-text*} fixtures as HTTP
 * responses: each fixture's {@code jsonText}, served as UTF-8 bytes with
 * {@code application/json}, must reach the engine input exactly as the
 * fixture's {@code errorResponseBody}. {@code EvidenceFixturesDeviceTest}
 * (tugboat-android) runs the same inputs through the real engine against
 * {@code expected.data}. A fixture whose text holds a lone surrogate has no
 * UTF-8 bytes (an HTTP body cannot carry it) and is checked only there.
 */
@RunWith(RobolectricTestRunner.class)
public class TugboatOkHttpFixturesTest {
    @Test
    public void everyJsonTextFixtureBodyReachesTheEngineInputUnchanged() throws Exception {
        File dir = new File(System.getProperty("tugboat.evidenceFixtures"), "network_call");
        File[] files = dir.listFiles((parent, name) -> name.contains("json-text") && name.endsWith(".json"));
        assertTrue("fixtures at " + dir, files != null && files.length >= 10);
        List<String> mismatches = new ArrayList<>();
        int served = 0;
        for (File file : files) {
            JSONObject input = new JSONObject(new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8)).getJSONObject("input");
            String text = input.getJSONObject("errorResponseBody").getString("jsonText");
            if (hasLoneSurrogate(text)) continue;
            served++;
            String mismatch = serve(file.getName(), input, text);
            if (mismatch != null) mismatches.add(mismatch);
        }
        assertTrue(served >= 9);
        assertEquals(String.join("\n", mismatches), 0, mismatches.size());
    }

    /** Null when the engine input carries the fixture's body, status, method, and route. */
    private static String serve(String name, JSONObject input, String text) throws Exception {
        MockWebServer server = new MockWebServer();
        server.start();
        try (EvidenceTap tap = new EvidenceTap()) {
            server.enqueue(new MockResponse()
                    .setResponseCode(input.getInt("statusCode"))
                    .setHeader("Content-Type", "application/json; charset=utf-8")
                    .setBody(new Buffer().write(text.getBytes(StandardCharsets.UTF_8))));
            String route = input.getString("route");
            OkHttpClient client = new OkHttpClient.Builder().addInterceptor(new TugboatOkHttpInterceptor(request -> route)).build();
            Request request = new Request.Builder().url(server.url("/fixture")).method(input.getString("method"), null).build();
            try (Response response = client.newCall(request).execute()) {
                String read = response.body().string();
                if (!read.equals(text)) return name + ": the app read a different body";
            }
            List<String> messages = tap.raw();
            if (messages.size() != 1) return name + ": " + messages.size() + " messages";
            JSONObject sent = new JSONObject(messages.get(0));
            String expected = input.getJSONObject("errorResponseBody").toString();
            String actual = sent.getJSONObject("errorResponseBody").toString();
            boolean same = expected.equals(actual)
                    && sent.getInt("statusCode") == input.getInt("statusCode")
                    && sent.getString("method").equals(input.getString("method"))
                    && sent.getString("route").equals(route)
                    && sent.getString("outcome").equals("response");
            return same ? null : name + "\n  expected " + expected + "\n  actual   " + actual + " in " + messages.get(0);
        } finally {
            server.shutdown();
        }
    }

    private static boolean hasLoneSurrogate(String text) {
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (Character.isHighSurrogate(c) && i + 1 < text.length() && Character.isLowSurrogate(text.charAt(i + 1))) {
                i++;
            } else if (Character.isSurrogate(c)) {
                return true;
            }
        }
        return false;
    }
}
