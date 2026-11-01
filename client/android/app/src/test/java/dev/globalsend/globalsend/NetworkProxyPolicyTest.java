package dev.globalsend.globalsend;

import android.net.Network;
import io.flutter.plugin.common.MethodCall;
import java.net.Proxy;
import java.net.URL;
import java.net.URLConnection;
import java.util.Map;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.Implementation;
import org.robolectric.annotation.Implements;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@Config(sdk=34, manifest=Config.NONE, shadows=NetworkProxyPolicyTest.Connections.class)
public class NetworkProxyPolicyTest {
    @Implements(Network.class)
    public static class Connections {
        static Proxy proxy;
        static boolean system;
        @Implementation protected URLConnection openConnection(URL url) {
            system = true; proxy = null; return connection(url);
        }
        @Implementation protected URLConnection openConnection(URL url, Proxy selected) {
            system = false; proxy = selected; return connection(url);
        }
        private static URLConnection connection(URL url) {
            return new URLConnection(url) { public void connect() {} };
        }
    }
    @Test public void defaultsToNoProxyOnTheSelectedNetworkAndRestoresSystemWhenDisabled() throws Exception {
        Network network = org.robolectric.shadows.ShadowNetwork.newInstance(42);
        URL url = new URL("https://example.test/path");
        for (Map<String, Object> args : java.util.List.<Map<String,Object>>of(Map.of(), Map.of("bypassSystemProxy", true))) {
            URLConnection connection = NativeReceiveRuntime.openNetworkConnection(network, url, new MethodCall("probe", args));
            assertEquals(url, connection.getURL());
            assertFalse(Connections.system);
            assertSame(Proxy.NO_PROXY, Connections.proxy);
        }
        NativeReceiveRuntime.openNetworkConnection(network, url, new MethodCall("putFile", Map.of("bypassSystemProxy", false)));
        assertTrue(Connections.system);
    }
}
