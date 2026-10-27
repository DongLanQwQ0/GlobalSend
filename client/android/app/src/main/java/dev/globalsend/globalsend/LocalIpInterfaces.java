package dev.globalsend.globalsend;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.LinkAddress;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Build;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.SocketException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Enumeration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** A user-requested local snapshot, without network requests or new permissions. */
final class LocalIpInterfaces {
    private LocalIpInterfaces() {}

    @SuppressWarnings("deprecation") // A one-shot menu snapshot, not a connectivity monitor.
    static List<Map<String, Object>> read(Context context) throws SocketException {
        Map<String, Map<String, Object>> interfaces = new LinkedHashMap<>();
        Enumeration<NetworkInterface> enumeration = NetworkInterface.getNetworkInterfaces();
        if (enumeration != null) {
            for (NetworkInterface network : Collections.list(enumeration)) {
                if (!network.isUp() || network.isLoopback()) continue;
                Map<String, Object> item = create(network.getName());
                item.put("displayName", network.getDisplayName());
                for (InetAddress address : Collections.list(network.getInetAddresses())) {
                    addAddress(item, address);
                }
                interfaces.put(network.getName(), item);
            }
        }
        ConnectivityManager manager = (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
        if (manager != null) {
            for (Network network : manager.getAllNetworks()) {
                LinkProperties properties = manager.getLinkProperties(network);
                NetworkCapabilities capabilities = manager.getNetworkCapabilities(network);
                if (properties == null || properties.getInterfaceName() == null) continue;
                String name = properties.getInterfaceName();
                Map<String, Object> item = interfaces.get(name);
                if (item == null) { item = create(name); interfaces.put(name, item); }
                for (LinkAddress address : properties.getLinkAddresses()) addAddress(item, address.getAddress());
                if (capabilities != null) {
                    item.put("kind", kind(capabilities));
                    item.put("internet", capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET));
                    // Android normally redacts another app's owner UID. An absent
                    // owner stays absent; interface names never imply an app owner.
                    if (Build.VERSION.SDK_INT >= 30 && capabilities.getOwnerUid() >= 0) {
                        String owner = owner(context, capabilities.getOwnerUid());
                        if (!owner.isEmpty()) item.put("owner", owner);
                    }
                }
            }
        }
        List<Map<String, Object>> result = new ArrayList<>();
        for (Map<String, Object> item : interfaces.values()) {
            if (!addresses(item).isEmpty()) result.add(item);
        }
        return result;
    }

    static String kind(NetworkCapabilities capabilities) {
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return "VPN";
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return "Wi-Fi";
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
            if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_IMS) &&
                    !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return "IMS 通话网络";
            return "蜂窝网络";
        }
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) return "以太网";
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH)) return "蓝牙网络";
        return "网卡";
    }

    static Map<String, Object> create(String name) {
        Map<String, Object> item = new LinkedHashMap<>();
        item.put("id", name); item.put("name", name); item.put("kind", "网卡");
        item.put("addresses", new ArrayList<String>());
        return item;
    }
    @SuppressWarnings("unchecked")
    static List<String> addresses(Map<String, Object> item) {
        return (List<String>) item.get("addresses");
    }
    static void addAddress(Map<String, Object> item, InetAddress address) {
        if (address.isLoopbackAddress() || address.isAnyLocalAddress() || address.isMulticastAddress()) return;
        String value = address.getHostAddress();
        if (value != null && !addresses(item).contains(value)) addresses(item).add(value);
    }
    private static String owner(Context context, int uid) {
        PackageManager packages = context.getPackageManager();
        String[] names = packages.getPackagesForUid(uid);
        if (names == null || names.length != 1) return "";
        try {
            ApplicationInfo app = packages.getApplicationInfo(names[0], 0);
            String label = packages.getApplicationLabel(app).toString();
            return label.equals(names[0]) ? names[0] : label + " (" + names[0] + ")";
        } catch (PackageManager.NameNotFoundException ignored) {
            return names[0];
        }
    }
}
