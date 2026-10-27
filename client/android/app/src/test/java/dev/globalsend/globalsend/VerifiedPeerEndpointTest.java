package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import io.flutter.plugin.common.MethodCall;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import org.robolectric.util.ReflectionHelpers;
import org.robolectric.util.ReflectionHelpers.ClassParameter;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28)
public class VerifiedPeerEndpointTest {
    private String selected(Map<String, Object> args) {
        return ReflectionHelpers.callStaticMethod(NativeReceiveRuntime.class, "verifiedCandidate",
            ClassParameter.from(MethodCall.class, new MethodCall("downloadPeer", args)),
            ClassParameter.from(List.class, Collections.singletonList("https://[240e::2]:9443")));
    }
    @Test public void verifiedCellularEndpointSkipsTheLegacyProbeSelection() {
        Map<String, Object> args = new HashMap<>();
        args.put("verifiedCandidate", "https://[240e::2]:9443");
        assertEquals("https://[240e::2]:9443", selected(args));
    }
    @Test public void existingCallersWithoutEvidenceKeepTheirProbeSelection() {
        assertNull(selected(Collections.emptyMap()));
    }
}
