package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.content.Context;
import android.net.ConnectivityManager;
import android.net.LinkAddress;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import java.net.InetAddress;
import java.util.List;
import java.util.Map;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.Implementation;
import org.robolectric.annotation.Implements;
import org.robolectric.shadows.ShadowConnectivityManager;
import org.robolectric.shadows.ShadowNetwork;
import org.robolectric.shadows.ShadowNetworkCapabilities;
import org.robolectric.shadow.api.Shadow;
import org.robolectric.util.ReflectionHelpers;
import org.robolectric.util.ReflectionHelpers.ClassParameter;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28, manifest = Config.NONE, shadows = LocalIpInterfacesTest.Networks.class)
public class LocalIpInterfacesTest {
    @Implements(ConnectivityManager.class)
    public static class Networks extends ShadowConnectivityManager {
        @Implementation protected Network[] getAllNetworks() { return new Network[]{ShadowNetwork.newInstance(101), ShadowNetwork.newInstance(102), ShadowNetwork.newInstance(103)}; }
        @Implementation protected LinkProperties getLinkProperties(Network network) {
            LinkProperties properties = new LinkProperties();
            String name = network.equals(ShadowNetwork.newInstance(101)) ? "test_rmnet_ims" :
                network.equals(ShadowNetwork.newInstance(102)) ? "test_rmnet_internet" : "test_vpn";
            properties.setInterfaceName(name);
            try {
                LinkAddress address = ReflectionHelpers.callConstructor(LinkAddress.class,
                    ClassParameter.from(InetAddress.class, InetAddress.getByName(name.equals("test_vpn") ? "198.18.0.1" : "240e::5")),
                    ClassParameter.from(int.class, name.equals("test_vpn") ? 30 : 64));
                ReflectionHelpers.callInstanceMethod(properties, "addLinkAddress", ClassParameter.from(LinkAddress.class, address));
            } catch (java.net.UnknownHostException impossible) { throw new AssertionError(impossible); }
            return properties;
        }
        @Implementation protected NetworkCapabilities getNetworkCapabilities(Network network) {
            NetworkCapabilities capabilities = ShadowNetworkCapabilities.newInstance();
            ShadowNetworkCapabilities shadow = Shadow.extract(capabilities);
            if (network.equals(ShadowNetwork.newInstance(103))) shadow.addTransportType(NetworkCapabilities.TRANSPORT_VPN);
            else shadow.addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR);
            if (network.equals(ShadowNetwork.newInstance(101))) shadow.addCapability(NetworkCapabilities.NET_CAPABILITY_IMS);
            else shadow.addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET);
            return capabilities;
        }
    }

    @Test public void sourceUsesNetworkCapabilitiesNotAnInterfaceNameGuess() throws Exception {
        List<Map<String,Object>> values = LocalIpInterfaces.read(RuntimeEnvironment.getApplication());
        Map<String,Object> ims = values.stream().filter(v -> "test_rmnet_ims".equals(v.get("name"))).findFirst().get();
        Map<String,Object> internet = values.stream().filter(v -> "test_rmnet_internet".equals(v.get("name"))).findFirst().get();
        Map<String,Object> vpn = values.stream().filter(v -> "test_vpn".equals(v.get("name"))).findFirst().get();
        assertEquals("IMS 通话网络", ims.get("kind")); assertEquals(false, ims.get("internet"));
        assertEquals("蜂窝网络", internet.get("kind")); assertEquals(true, internet.get("internet"));
        assertEquals("VPN", vpn.get("kind")); assertFalse(vpn.containsKey("owner"));
        assertEquals(ims.get("addresses"), internet.get("addresses")); // Duplicate IP, separate providers.
    }
    @Test public void loopbacksAreRemovedButActualInterfaceAndReservedVpnAddressesRemain() throws Exception {
        Map<String,Object> item = LocalIpInterfaces.create("tun0");
        LocalIpInterfaces.addAddress(item, InetAddress.getByName("127.6.5.4"));
        LocalIpInterfaces.addAddress(item, InetAddress.getByName("::1"));
        LocalIpInterfaces.addAddress(item, InetAddress.getByName("::ffff:127.0.0.1"));
        LocalIpInterfaces.addAddress(item, InetAddress.getByName("198.18.0.1"));
        LocalIpInterfaces.addAddress(item, InetAddress.getByName("198.18.0.1"));
        assertEquals(java.util.Collections.singletonList("198.18.0.1"), item.get("addresses"));
        assertEquals("tun0", item.get("name")); assertFalse(item.containsKey("owner"));
    }
}
