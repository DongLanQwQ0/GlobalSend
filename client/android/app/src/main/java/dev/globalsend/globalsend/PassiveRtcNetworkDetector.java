package dev.globalsend.globalsend;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.LinkAddress;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import java.util.ArrayList;
import java.util.List;
import org.webrtc.NetworkChangeDetector;

/**
 * Observe WebRTC networks without NetworkMonitorAutoDetect's unconditional
 * requestMobileNetwork. Only an authorized file session owns a mobile lease.
 */
final class PassiveRtcNetworkDetector implements NetworkChangeDetector {
    private final ConnectivityManager manager;
    private final Observer observer;
    private volatile boolean closed;
    private final ConnectivityManager.NetworkCallback callback = new ConnectivityManager.NetworkCallback() {
        @Override public void onAvailable(Network network) { publish(network); }
        @Override public void onLinkPropertiesChanged(Network network, LinkProperties properties) { publish(network); }
        @Override public void onCapabilitiesChanged(Network network, NetworkCapabilities caps) { publish(network); }
        @Override public void onLost(Network network) {
            if (!closed) { observer.onNetworkDisconnect(network.getNetworkHandle()); changed(); }
        }
    };
    PassiveRtcNetworkDetector(Observer observer, Context context) {
        this.observer = observer;
        manager = (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
        // clearCapabilities also observes local-only Wi-Fi. This is a passive
        // callback, not requestNetwork, and does not keep cellular active.
        manager.registerNetworkCallback(new NetworkRequest.Builder().clearCapabilities().build(), callback);
    }
    private void changed() { observer.onConnectionTypeChanged(getCurrentConnectionType()); }
    private void publish(Network network) {
        if (closed) return;
        NetworkInformation info = information(network);
        if (info != null) observer.onNetworkConnect(info);
        changed();
    }
    static String networkKind(NetworkCapabilities caps) {
        if (caps == null) return "unknown";
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return "vpn";
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) return "cellular";
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return "wifi";
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) return "ethernet";
        return "unknown";
    }
    private static ConnectionType connectionType(NetworkCapabilities caps) {
        return switch (networkKind(caps)) {
            case "vpn" -> ConnectionType.CONNECTION_VPN;
            case "cellular" -> ConnectionType.CONNECTION_UNKNOWN_CELLULAR;
            case "wifi" -> ConnectionType.CONNECTION_WIFI;
            case "ethernet" -> ConnectionType.CONNECTION_ETHERNET;
            default -> ConnectionType.CONNECTION_UNKNOWN;
        };
    }
    private NetworkInformation information(Network network) {
        LinkProperties properties = manager.getLinkProperties(network);
        if (properties == null || properties.getInterfaceName() == null || properties.getLinkAddresses().isEmpty()) return null;
        List<IPAddress> addresses = new ArrayList<>();
        for (LinkAddress address : properties.getLinkAddresses()) addresses.add(new IPAddress(address.getAddress().getAddress()));
        return new NetworkInformation(properties.getInterfaceName(), connectionType(manager.getNetworkCapabilities(network)),
            ConnectionType.CONNECTION_UNKNOWN, network.getNetworkHandle(), addresses.toArray(new IPAddress[0]), NetworkSlice.NO_SLICE);
    }
    @Override public ConnectionType getCurrentConnectionType() {
        Network current = manager.getActiveNetwork();
        return current == null ? ConnectionType.CONNECTION_NONE : connectionType(manager.getNetworkCapabilities(current));
    }
    @Override public boolean supportNetworkCallback() { return true; }
    @Override public List<NetworkInformation> getActiveNetworkList() {
        List<NetworkInformation> values = new ArrayList<>();
        for (Network network : manager.getAllNetworks()) {
            NetworkInformation info = information(network);
            if (info != null) values.add(info);
        }
        return values;
    }
    @Override public void destroy() {
        if (closed) return;
        closed = true;
        manager.unregisterNetworkCallback(callback);
    }
}
