package dev.globalsend.globalsend;

import android.net.ConnectivityManager;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;

/** One file attempt keeps cellular available; never binds the process. */
final class RtcCellularLease implements AutoCloseable {
    private final ConnectivityManager manager;
    private final ConnectivityManager.NetworkCallback callback = new ConnectivityManager.NetworkCallback();
    private boolean closed;
    RtcCellularLease(ConnectivityManager manager) {
        this.manager = manager;
        manager.requestNetwork(new NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build(), callback);
    }
    @Override public void close() {
        if (closed) return;
        closed = true;
        manager.unregisterNetworkCallback(callback);
    }
}
