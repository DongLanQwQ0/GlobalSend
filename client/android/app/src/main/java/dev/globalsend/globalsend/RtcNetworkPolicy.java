package dev.globalsend.globalsend;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.Map;
import org.webrtc.PeerConnectionFactory;

/** Per-attempt permission, independent of ICE's cost/preference heuristics. */
final class RtcNetworkPolicy {
    final boolean cellular;
    RtcNetworkPolicy(String scope, boolean permission) {
        cellular = "public".equals(scope) && permission;
    }
    int ignoreMask() {
        if (cellular) return 0;
        // Include the detailed cellular types when SurfaceCellularTypes is
        // enabled. VPN/ANY cannot establish the underlying billable network.
        return PeerConnectionFactory.Options.ADAPTER_TYPE_CELLULAR
            | PeerConnectionFactory.Options.ADAPTER_TYPE_VPN
            | PeerConnectionFactory.Options.ADAPTER_TYPE_ANY
            | (1 << 6) | (1 << 7) | (1 << 8) | (1 << 9);
    }
    boolean permits(String network) {
        return cellular || "wifi".equals(network) || "ethernet".equals(network);
    }

    static final class Gate {
        private final RtcNetworkPolicy policy;
        private boolean selected;
        private String network = "unknown";
        private String reportedNetwork = "", reportedFamily = "";
        Gate(RtcNetworkPolicy policy) { this.policy = policy; }
        void selected(boolean selected, String network) { this.selected = selected; this.network = network; }
        void requireFrame() {
            if (!selected || !policy.permits(network)) {
                throw new IllegalStateException("Selected RTC network is not permitted: " + network);
            }
        }
        boolean reportChanged(String network, String family) {
            if (network.equals(reportedNetwork) && family.equals(reportedFamily)) return false;
            reportedNetwork = network; reportedFamily = family;
            return true;
        }
    }

    /** Only the owning native worker accesses this registry. */
    static final class Owners<T extends Owner> {
        private final Map<String, T> values = new LinkedHashMap<>();
        void add(String id, T value) {
            if (values.containsKey(id)) throw new IllegalStateException("RTC session already exists");
            values.put(id, value);
        }
        T get(String id) { return values.get(id); }
        void close(String id) {
            T value = values.remove(id);
            if (value != null) value.close();
        }
        void revokeCellular() {
            RuntimeException failure = null;
            for (String id : new ArrayList<>(values.keySet())) {
                if (values.get(id).cellular()) {
                    try { close(id); } catch (RuntimeException error) { failure = error; }
                }
            }
            if (failure != null) throw failure;
        }
        void closeAll() {
            RuntimeException failure = null;
            for (String id : new ArrayList<>(values.keySet())) {
                try { close(id); } catch (RuntimeException error) { failure = error; }
            }
            if (failure != null) throw failure;
        }
    }
    interface Owner { boolean cellular(); void close(); }
}
