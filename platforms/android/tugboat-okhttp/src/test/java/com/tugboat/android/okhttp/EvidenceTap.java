package com.tugboat.android.okhttp;

import com.tugboat.android.adapter.TugboatAdapters;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import kotlin.Unit;

/**
 * The `evidence.networkCall` engine inputs recorded while open, through
 * {@link TugboatAdapters#tapEvidenceForTesting}: the real recorder and
 * encoder, with the engine replaced by this list.
 *
 * <p>Written in Java, like the interceptor tests, so the same sources compile
 * against OkHttp 3.14 ({@code body()}) and 4.x/5.x (the {@code body} property,
 * {@code body()} from Java).
 */
final class EvidenceTap implements AutoCloseable {
    private final List<String> networkCalls = new CopyOnWriteArrayList<>();
    private final List<String> other = new CopyOnWriteArrayList<>();
    private final AutoCloseable handle;

    EvidenceTap() {
        handle = TugboatAdapters.tapEvidenceForTesting((type, input) -> {
            (type.equals("evidence.networkCall") ? networkCalls : other).add(input);
            return Unit.INSTANCE;
        });
    }

    /** Each message with its times replaced by {@code S} and {@code E}, after checking that start is not after end. */
    List<String> networkCalls() {
        if (!other.isEmpty()) throw new AssertionError("unexpected evidence: " + other);
        List<String> out = new ArrayList<>();
        for (String message : networkCalls) {
            java.util.regex.Matcher times = java.util.regex.Pattern
                    .compile("\"startMonoUs\":(\\d+),\"endMonoUs\":(\\d+)")
                    .matcher(message);
            if (!times.find()) throw new AssertionError("no times in " + message);
            if (Long.parseLong(times.group(1)) > Long.parseLong(times.group(2))) {
                throw new AssertionError("start after end in " + message);
            }
            out.add(times.replaceFirst("\"startMonoUs\":S,\"endMonoUs\":E"));
        }
        return out;
    }

    /** The raw messages, times included. */
    List<String> raw() {
        return new ArrayList<>(networkCalls);
    }

    @Override
    public void close() throws Exception {
        handle.close();
    }
}
