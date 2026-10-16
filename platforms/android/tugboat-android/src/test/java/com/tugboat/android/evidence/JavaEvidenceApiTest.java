package com.tugboat.android.evidence;

import static org.junit.Assert.assertNotNull;

import com.tugboat.android.EventHook;
import com.tugboat.android.NetworkCall;
import com.tugboat.android.NetworkFailure;
import com.tugboat.android.ParameterPolicy;
import com.tugboat.android.Tugboat;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import org.junit.Test;

/** The evidence API reads naturally from Java: static calls, overloads, and the policy constants. */
public class JavaEvidenceApiTest {
    @Test
    public void everyCallShapeCompilesAndIsSafeBeforeStart() {
        EventHook all = Tugboat.eventHook();
        EventHook named = Tugboat.eventHook("analytics");
        EventHook allowed = Tugboat.eventHook("analytics", ParameterPolicy.allowList(Collections.singleton("method")));
        EventHook names = Tugboat.eventHook(null, ParameterPolicy.namesOnly);
        EventHook transformed = Tugboat.eventHook(
                "analytics", ParameterPolicy.transform((key, value) -> key.equals("secret") ? ParameterPolicy.DROP : value));
        Map<String, Object> parameters = new HashMap<>();
        parameters.put("method", "email");
        all.record("USER_LOGIN");
        named.record("USER_LOGIN", parameters);
        allowed.record("USER_LOGIN", parameters);
        names.record("USER_LOGIN", parameters);
        transformed.record("USER_LOGIN", parameters);
        assertNotNull(ParameterPolicy.allowAll);

        NetworkCall call = Tugboat.beginNetworkCall("GET", "/orders/123");
        call.complete();
        call.complete(200);
        call.complete(422, 1);
        call.complete(422, null, parameters);
        call.fail(NetworkFailure.NETWORK_ERROR);
        call.fail(NetworkFailure.CANCELLED, null);
        call.fail(NetworkFailure.NETWORK_ERROR, 503, 3, "unavailable");
    }
}
