package com.tugboat.android.okhttp;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.io.IOException;
import java.io.InterruptedIOException;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import kotlin.jvm.functions.Function1;
import okhttp3.Call;
import okhttp3.Interceptor;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import okhttp3.mockwebserver.MockResponse;
import okhttp3.mockwebserver.MockWebServer;
import okhttp3.mockwebserver.RecordedRequest;
import okio.Buffer;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

/**
 * The interceptor against a real OkHttp client and MockWebServer, with the
 * engine messages captured on the evidence path ({@link EvidenceTap}). Runs
 * on the OkHttp version of {@code -Ptugboat.okhttpTest} (build.gradle.kts).
 */
@RunWith(RobolectricTestRunner.class)
public class TugboatOkHttpInterceptorTest {
    private static final String SECRET_QUERY = "SECRET_QUERY";
    private static final String SECRET_HEADER = "SECRET_HEADER";
    private static final String SECRET_BODY = "SECRET_BODY";

    /** The path, so the query never reaches the route. */
    private static final Function1<Request, String> PATH = request -> request.url().encodedPath();

    private final MockWebServer server = new MockWebServer();
    private EvidenceTap tap;

    @Before
    public void setUp() throws IOException {
        server.start();
        tap = new EvidenceTap();
    }

    @After
    public void tearDown() throws Exception {
        tap.close();
        server.shutdown();
    }

    private OkHttpClient.Builder builder(Interceptor... inner) {
        OkHttpClient.Builder builder = new OkHttpClient.Builder().addInterceptor(new TugboatOkHttpInterceptor(PATH));
        for (Interceptor interceptor : inner) builder.addInterceptor(interceptor);
        return builder;
    }

    private Request get(String path) {
        return new Request.Builder()
                .url(server.url(path + "?token=" + SECRET_QUERY))
                .header("Authorization", "Bearer " + SECRET_HEADER)
                .build();
    }

    private static String call(String method, String route, String rest) {
        return "{\"method\":\"" + method + "\",\"route\":\"" + route + "\",\"startMonoUs\":S,\"endMonoUs\":E," + rest + "}";
    }

    private static String readBody(Response response) throws IOException {
        try {
            return response.body().string();
        } finally {
            response.close();
        }
    }

    private void assertNoSecrets() {
        for (String message : tap.raw()) {
            assertFalse(message, message.contains(SECRET_QUERY));
            assertFalse(message, message.contains(SECRET_HEADER));
            assertFalse(message, message.contains(SECRET_BODY));
            assertFalse(message, message.contains("token"));
            assertFalse(message, message.contains("Authorization"));
            assertFalse(message, message.contains("localhost"));
        }
    }

    @Test
    public void a200IsOneResponseWithItsStatusAndNoBody() throws Exception {
        server.enqueue(new MockResponse().setBody("hello"));

        Response response = builder().build().newCall(get("/orders/42")).execute();

        assertEquals("hello", readBody(response));
        assertEquals(
                Collections.singletonList(call("GET", "/orders/42", "\"statusCode\":200,\"outcome\":\"response\"")),
                tap.networkCalls());
        assertNoSecrets();
    }

    @Test
    public void a404WithAJsonBodyIsSentAsJsonTextAndTheAppReadsItIntact() throws Exception {
        String body = "{\"code\":\"order_missing\",\"detail\":\"Order 42 is gone\"}";
        server.enqueue(new MockResponse()
                .setResponseCode(404)
                .setHeader("Content-Type", "application/problem+json; charset=utf-8")
                .setBody(body));

        Response response = builder().build().newCall(get("/orders/42")).execute();

        assertEquals(404, response.code());
        assertEquals(body, readBody(response));
        assertEquals(
                Collections.singletonList(call("GET", "/orders/42",
                        "\"statusCode\":404,\"outcome\":\"response\",\"errorResponseBody\":{\"jsonText\":"
                                + "\"{\\\"code\\\":\\\"order_missing\\\",\\\"detail\\\":\\\"Order 42 is gone\\\"}\"}")),
                tap.networkCalls());
        assertNoSecrets();
    }

    @Test
    public void a500WithATextBodyIsSentAsText() throws Exception {
        server.enqueue(new MockResponse()
                .setResponseCode(500)
                .setHeader("Content-Type", "text/plain")
                .setBody("upstream exploded"));

        Response response = builder().build().newCall(get("/checkout")).execute();

        assertEquals("upstream exploded", readBody(response));
        assertEquals(
                Collections.singletonList(call("GET", "/checkout",
                        "\"statusCode\":500,\"outcome\":\"response\",\"errorResponseBody\":{\"value\":\"upstream exploded\"}")),
                tap.networkCalls());
    }

    @Test
    public void aJsonBodyOver64KibIsTextCutTo4100BytesAndTheAppReadsItAll() throws Exception {
        StringBuilder body = new StringBuilder("{\"pad\":\"");
        while (body.length() < 70_000) body.append("0123456789");
        body.append("\"}");
        server.enqueue(new MockResponse()
                .setResponseCode(502)
                .setHeader("Content-Type", "application/json")
                .setBody(body.toString()));

        Response response = builder().build().newCall(get("/big")).execute();

        assertEquals(body.toString(), readBody(response));
        // Text: the adapter keeps 4100 bytes, the encoder 4097 units of them (both exact for the engine's 4096-byte cut).
        String expectedText = body.substring(0, 4_097).replace("\"", "\\\"");
        assertEquals(
                Collections.singletonList(call("GET", "/big",
                        "\"statusCode\":502,\"outcome\":\"response\",\"errorResponseBody\":{\"value\":\"" + expectedText + "\"}")),
                tap.networkCalls());
    }

    @Test
    public void aJsonBodyOfExactly64KibIsComplete() throws Exception {
        String body = jsonOfLength(65_536);
        server.enqueue(new MockResponse().setResponseCode(500).setHeader("Content-Type", "application/json").setBody(body));
        server.enqueue(new MockResponse().setResponseCode(500).setHeader("Content-Type", "application/json").setBody(body + " "));
        OkHttpClient client = builder().build();

        assertEquals(body, readBody(client.newCall(get("/exact")).execute()));
        assertEquals(body + " ", readBody(client.newCall(get("/over")).execute()));

        List<String> calls = tap.networkCalls();
        assertTrue(calls.get(0), calls.get(0).contains("\"errorResponseBody\":{\"jsonText\":"));
        assertTrue(calls.get(1), calls.get(1).contains("\"errorResponseBody\":{\"value\":"));
    }

    /** {@code ["xx\u2026x"]} of exactly {@code length} bytes. */
    private static String jsonOfLength(int length) {
        StringBuilder body = new StringBuilder("[\"");
        while (body.length() < length - 2) body.append('x');
        return body.append("\"]").toString();
    }

    @Test
    public void aStatusBelow400NeverReadsTheBody() throws Exception {
        server.enqueue(new MockResponse().setResponseCode(399).setHeader("Content-Type", "application/json").setBody("{\"a\":1}"));

        assertEquals("{\"a\":1}", readBody(builder().build().newCall(get("/r")).execute()));
        assertEquals(
                Collections.singletonList(call("GET", "/r", "\"statusCode\":399,\"outcome\":\"response\"")),
                tap.networkCalls());
    }

    @Test
    public void aReadTimeoutIsANetworkErrorAndIsRethrown() throws Exception {
        server.enqueue(new MockResponse().setHeadersDelay(5, TimeUnit.SECONDS));
        OkHttpClient client = builder().readTimeout(200, TimeUnit.MILLISECONDS).build();

        try {
            client.newCall(get("/slow")).execute();
            fail("expected a timeout");
        } catch (InterruptedIOException expected) {
            // The app sees OkHttp's own timeout.
        }
        assertEquals(
                Collections.singletonList(call("GET", "/slow", "\"outcome\":\"network_error\"")),
                tap.networkCalls());
        assertNoSecrets();
    }

    @Test
    public void aCallTimeoutIsANetworkErrorNotACancel() throws Exception {
        server.enqueue(new MockResponse().setHeadersDelay(5, TimeUnit.SECONDS));
        OkHttpClient client = builder().callTimeout(300, TimeUnit.MILLISECONDS).build();

        try {
            client.newCall(get("/slow")).execute();
            fail("expected a timeout");
        } catch (IOException expected) {
            // OkHttp cancels the call at its deadline.
        }
        assertEquals(
                Collections.singletonList(call("GET", "/slow", "\"outcome\":\"network_error\"")),
                tap.networkCalls());
    }

    @Test
    public void aCancelledCallIsCancelledAndIsRethrown() throws Exception {
        server.enqueue(new MockResponse().setHeadersDelay(5, TimeUnit.SECONDS));
        Call call = builder().build().newCall(get("/feed"));
        AtomicReference<Throwable> thrown = new AtomicReference<>();
        Thread caller = new Thread(() -> {
            try {
                call.execute().close();
            } catch (Throwable failure) {
                thrown.set(failure);
            }
        });
        caller.start();
        server.takeRequest(5, TimeUnit.SECONDS);
        call.cancel();
        caller.join(5_000);

        assertTrue(String.valueOf(thrown.get()), thrown.get() instanceof IOException);
        assertEquals(
                Collections.singletonList(call("GET", "/feed", "\"outcome\":\"cancelled\"")),
                tap.networkCalls());
    }

    @Test
    public void aCallCancelledBeforeItRunsIsCancelled() throws Exception {
        Call call = builder().build().newCall(get("/feed"));
        call.cancel();

        try {
            call.execute();
            fail("expected a cancel");
        } catch (IOException expected) {
            // OkHttp's "Canceled".
        }
        assertEquals(
                Collections.singletonList(call("GET", "/feed", "\"outcome\":\"cancelled\"")),
                tap.networkCalls());
    }

    @Test
    public void anAsyncCallIsRecordedOnTheDispatcherThread() throws Exception {
        server.enqueue(new MockResponse().setResponseCode(503).setHeader("Content-Type", "text/plain").setBody("busy"));
        CountDownLatch done = new CountDownLatch(1);
        AtomicReference<String> body = new AtomicReference<>();
        builder().build().newCall(get("/async")).enqueue(new okhttp3.Callback() {
            @Override
            public void onFailure(Call call, IOException e) {
                done.countDown();
            }

            @Override
            public void onResponse(Call call, Response response) throws IOException {
                body.set(readBody(response));
                done.countDown();
            }
        });

        assertTrue(done.await(5, TimeUnit.SECONDS));
        assertEquals("busy", body.get());
        assertEquals(
                Collections.singletonList(call("GET", "/async",
                        "\"statusCode\":503,\"outcome\":\"response\",\"errorResponseBody\":{\"value\":\"busy\"}")),
                tap.networkCalls());
    }

    @Test
    public void aRedirectIsOneCallWithTheFinalStatus() throws Exception {
        server.enqueue(new MockResponse().setResponseCode(302).setHeader("Location", "/final"));
        server.enqueue(new MockResponse().setBody("landed"));

        Response response = builder().build().newCall(get("/start")).execute();

        assertEquals("landed", readBody(response));
        assertEquals(2, server.getRequestCount());
        assertEquals(
                Collections.singletonList(call("GET", "/start", "\"statusCode\":200,\"outcome\":\"response\"")),
                tap.networkCalls());
    }

    /** Retries a 503 once, as an app's retry interceptor would. */
    private static final class RetryOnce implements Interceptor {
        final AtomicInteger attempts = new AtomicInteger();

        @Override
        public Response intercept(Chain chain) throws IOException {
            attempts.incrementAndGet();
            Response first = chain.proceed(chain.request());
            if (first.code() != 503) return first;
            first.close();
            attempts.incrementAndGet();
            return chain.proceed(chain.request());
        }
    }

    @Test
    public void anAppRetryInterceptorInsideIsOneCallWithoutAnAttemptCount() throws Exception {
        server.enqueue(new MockResponse().setResponseCode(503).setBody("busy"));
        server.enqueue(new MockResponse().setBody("ok"));
        RetryOnce retry = new RetryOnce();

        Response response = builder(retry).build().newCall(get("/orders")).execute();

        assertEquals("ok", readBody(response));
        assertEquals(2, retry.attempts.get());
        assertEquals(
                Collections.singletonList(call("GET", "/orders", "\"statusCode\":200,\"outcome\":\"response\"")),
                tap.networkCalls());
    }

    @Test
    public void anAppRetryInterceptorOutsideRecordsEachAttemptWhichIsWhyItGoesFirst() throws Exception {
        server.enqueue(new MockResponse().setResponseCode(503).setBody("busy"));
        server.enqueue(new MockResponse().setBody("ok"));
        OkHttpClient client = new OkHttpClient.Builder()
                .addInterceptor(new RetryOnce())
                .addInterceptor(new TugboatOkHttpInterceptor(PATH))
                .build();

        assertEquals("ok", readBody(client.newCall(get("/orders")).execute()));
        assertEquals(
                Arrays.asList(
                        call("GET", "/orders", "\"statusCode\":503,\"outcome\":\"response\",\"errorResponseBody\":{\"value\":\"busy\"}"),
                        call("GET", "/orders", "\"statusCode\":200,\"outcome\":\"response\"")),
                tap.networkCalls());
    }

    @Test
    public void aRequestBodyAndHeadersAreNeverRecordedAndReachTheServerUnchanged() throws Exception {
        server.enqueue(new MockResponse().setResponseCode(422).setHeader("Content-Type", "application/json").setBody("{\"field\":\"name\"}"));
        Request request = new Request.Builder()
                .url(server.url("/projects?token=" + SECRET_QUERY))
                .header("Authorization", "Bearer " + SECRET_HEADER)
                .post(RequestBody.create(MediaType.parse("text/plain"), SECRET_BODY))
                .build();

        Response response = builder().build().newCall(request).execute();

        assertEquals("{\"field\":\"name\"}", readBody(response));
        RecordedRequest recorded = server.takeRequest();
        assertEquals("/projects?token=" + SECRET_QUERY, recorded.getPath());
        assertEquals("Bearer " + SECRET_HEADER, recorded.getHeader("Authorization"));
        assertEquals(SECRET_BODY, recorded.getBody().readUtf8());
        assertEquals(
                Collections.singletonList(call("POST", "/projects",
                        "\"statusCode\":422,\"outcome\":\"response\",\"errorResponseBody\":{\"jsonText\":\"{\\\"field\\\":\\\"name\\\"}\"}")),
                tap.networkCalls());
        assertNoSecrets();
    }

    @Test
    public void aNullBlankOrThrowingResolverRecordsNothingAndTheCallIsUntouched() throws Exception {
        List<Function1<Request, String>> resolvers = Arrays.asList(
                request -> null,
                request -> "  \t ",
                request -> {
                    throw new IllegalStateException("resolver bug");
                });
        for (Function1<Request, String> resolver : resolvers) {
            server.enqueue(new MockResponse().setResponseCode(500).setHeader("Content-Type", "application/json").setBody("{\"e\":1}"));
            OkHttpClient client = new OkHttpClient.Builder().addInterceptor(new TugboatOkHttpInterceptor(resolver)).build();

            Response response = client.newCall(get("/r")).execute();

            assertEquals(500, response.code());
            assertEquals("{\"e\":1}", readBody(response));
            assertEquals("Bearer " + SECRET_HEADER, server.takeRequest().getHeader("Authorization"));
        }
        assertEquals(Collections.emptyList(), tap.networkCalls());
    }

    @Test
    public void theRouteIsTrimmedAsDartTrims() throws Exception {
        server.enqueue(new MockResponse());
        OkHttpClient client = new OkHttpClient.Builder()
                .addInterceptor(new TugboatOkHttpInterceptor(request -> " \u00A0/orders/{id}\uFEFF\n"))
                .build();

        readBody(client.newCall(get("/orders/42")).execute());

        assertEquals(
                Collections.singletonList(call("GET", "/orders/{id}", "\"statusCode\":200,\"outcome\":\"response\"")),
                tap.networkCalls());
    }

    @Test
    public void theResolverIsNotRunWhileTugboatTakesNoEvidence() throws Exception {
        tap.close();
        server.enqueue(new MockResponse());
        AtomicInteger resolved = new AtomicInteger();
        OkHttpClient client = new OkHttpClient.Builder()
                .addInterceptor(new TugboatOkHttpInterceptor(request -> {
                    resolved.incrementAndGet();
                    return "/r";
                }))
                .build();

        readBody(client.newCall(get("/r")).execute());

        assertEquals(0, resolved.get());
    }

    @Test
    public void asANetworkInterceptorItRecordsNothing() throws Exception {
        server.enqueue(new MockResponse().setResponseCode(302).setHeader("Location", "/final"));
        server.enqueue(new MockResponse().setBody("landed"));
        OkHttpClient client = new OkHttpClient.Builder().addNetworkInterceptor(new TugboatOkHttpInterceptor(PATH)).build();

        assertEquals("landed", readBody(client.newCall(get("/start")).execute()));
        assertEquals(Collections.emptyList(), tap.networkCalls());
    }

    @Test
    public void installedTwiceItRecordsOnce() throws Exception {
        server.enqueue(new MockResponse());
        OkHttpClient once = builder().build();
        OkHttpClient twice = once.newBuilder().addInterceptor(new TugboatOkHttpInterceptor(PATH)).build();

        readBody(twice.newCall(get("/r")).execute());

        assertEquals(
                Collections.singletonList(call("GET", "/r", "\"statusCode\":200,\"outcome\":\"response\"")),
                tap.networkCalls());
    }

    @Test
    public void aCallMadeInsideAnInterceptorIsItsOwnCall() throws Exception {
        server.enqueue(new MockResponse().setBody("token"));
        server.enqueue(new MockResponse().setBody("data"));
        OkHttpClient tokenClient = builder().build();
        Interceptor auth = chain -> {
            String token = readBody(tokenClient.newCall(new Request.Builder().url(server.url("/token")).build()).execute());
            return chain.proceed(chain.request().newBuilder().header("Authorization", token).build());
        };

        assertEquals("data", readBody(builder(auth).build().newCall(new Request.Builder().url(server.url("/data")).build()).execute()));

        assertEquals(
                Arrays.asList(
                        call("GET", "/token", "\"statusCode\":200,\"outcome\":\"response\""),
                        call("GET", "/data", "\"statusCode\":200,\"outcome\":\"response\"")),
                tap.networkCalls());
    }

    @Test
    public void anIOExceptionFromInsideIsANetworkErrorAndTheSameInstanceIsRethrown() throws Exception {
        IOException failure = new IOException("raw transport text " + SECRET_QUERY);
        Interceptor broken = chain -> {
            throw failure;
        };

        try {
            builder(broken).build().newCall(get("/r")).execute();
            fail("expected the failure");
        } catch (IOException thrown) {
            assertSame(failure, thrown);
        }
        assertEquals(
                Collections.singletonList(call("GET", "/r", "\"outcome\":\"network_error\"")),
                tap.networkCalls());
        assertNoSecrets();
    }

    @Test
    public void aRuntimeExceptionFromInsideIsRethrownUnchangedAndRecordsNothing() throws Exception {
        IllegalStateException bug = new IllegalStateException("app bug");
        Interceptor broken = chain -> {
            throw bug;
        };

        try {
            builder(broken).build().newCall(get("/r")).execute();
            fail("expected the failure");
        } catch (IllegalStateException thrown) {
            assertSame(bug, thrown);
        }
        assertEquals(Collections.emptyList(), tap.networkCalls());
    }

    @Test
    public void theResponseIsTheOneFromBelow() throws Exception {
        AtomicReference<Response> below = new AtomicReference<>();
        Interceptor inner = chain -> {
            Response response = chain.proceed(chain.request());
            below.set(response);
            return response;
        };
        server.enqueue(new MockResponse().setResponseCode(404).setHeader("Content-Type", "application/json").setBody(new Buffer().writeUtf8("{}")));

        Response response = builder(inner).build().newCall(get("/r")).execute();

        assertSame(below.get(), response);
        assertEquals("{}", readBody(response));
    }
}
