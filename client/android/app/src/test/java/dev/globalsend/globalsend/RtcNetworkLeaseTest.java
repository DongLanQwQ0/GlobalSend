package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.content.Context;
import android.net.ConnectivityManager;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.Implementation;
import org.robolectric.annotation.Implements;
import org.robolectric.shadows.ShadowConnectivityManager;
import org.webrtc.NetworkChangeDetector;

/** No JNI, device or system network changes. Tests Android callback ownership. */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28, manifest = Config.NONE, shadows = RtcNetworkLeaseTest.Requests.class)
public class RtcNetworkLeaseTest {
    @Implements(ConnectivityManager.class)
    public static class Requests extends ShadowConnectivityManager {
        static int observers, cellular, released;
        static final Set<ConnectivityManager.NetworkCallback> live = new HashSet<>();
        @Implementation protected void registerNetworkCallback(NetworkRequest request, ConnectivityManager.NetworkCallback callback) {
            observers++; live.add(callback);
        }
        @Implementation protected void requestNetwork(NetworkRequest request, ConnectivityManager.NetworkCallback callback) {
            assertTrue(request.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR));
            assertTrue(request.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET));
            cellular++; live.add(callback);
        }
        @Implementation protected void unregisterNetworkCallback(ConnectivityManager.NetworkCallback callback) {
            assertTrue("each callback is released once", live.remove(callback)); released++;
        }
    }
    @Before public void reset() { Requests.observers = Requests.cellular = Requests.released = 0; Requests.live.clear(); }
    @Test public void passiveDetectorNeverRequestsMobileAndEachCellularSessionReleasesItsOwnLease() {
        Context context = RuntimeEnvironment.getApplication();
        ConnectivityManager manager = (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
        NetworkChangeDetector.Observer observer = new NetworkChangeDetector.Observer() {
            @Override public void onConnectionTypeChanged(NetworkChangeDetector.ConnectionType type) {}
            @Override public void onNetworkConnect(NetworkChangeDetector.NetworkInformation info) {}
            @Override public void onNetworkDisconnect(long handle) {}
            @Override public void onNetworkPreference(List<NetworkChangeDetector.ConnectionType> types, int preference) {}
        };
        PassiveRtcNetworkDetector detector = new PassiveRtcNetworkDetector(observer, context);
        assertEquals(1, Requests.observers); assertEquals(0, Requests.cellular);
        RtcCellularLease first = new RtcCellularLease(manager), second = new RtcCellularLease(manager);
        assertEquals(2, Requests.cellular); assertEquals(3, Requests.live.size());
        first.close(); first.close(); assertEquals(2, Requests.live.size());
        detector.destroy(); detector.destroy(); assertEquals(1, Requests.live.size());
        second.close(); second.close(); assertEquals(0, Requests.live.size());
        assertEquals(3, Requests.released);
    }
}
