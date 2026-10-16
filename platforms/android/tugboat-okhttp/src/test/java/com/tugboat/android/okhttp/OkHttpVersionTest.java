package com.tugboat.android.okhttp;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

/** The tests run on the OkHttp version that {@code -Ptugboat.okhttpTest} names (build.gradle.kts). */
public class OkHttpVersionTest {
    @Test
    public void theClasspathHasTheRequestedOkHttp() throws Exception {
        assertEquals(System.getProperty("tugboat.okhttpTest"), okhttpVersion());
    }

    /** {@code okhttp3.OkHttp.VERSION} from 4.0, {@code okhttp3.internal.Version.userAgent()} before. */
    private static String okhttpVersion() throws Exception {
        try {
            return (String) Class.forName("okhttp3.OkHttp").getField("VERSION").get(null);
        } catch (ClassNotFoundException before4) {
            String userAgent = (String) Class.forName("okhttp3.internal.Version").getMethod("userAgent").invoke(null);
            return userAgent.substring("okhttp/".length());
        }
    }
}
