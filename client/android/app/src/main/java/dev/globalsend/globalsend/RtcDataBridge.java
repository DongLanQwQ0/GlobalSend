package dev.globalsend.globalsend;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.LinkAddress;
import android.net.LinkProperties;
import android.net.Network;
import android.os.Handler;
import android.os.Looper;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.net.InetAddress;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;
import org.webrtc.CandidatePairChangeEvent;
import org.webrtc.DataChannel;
import org.webrtc.IceCandidate;
import org.webrtc.MediaConstraints;
import org.webrtc.MediaStream;
import org.webrtc.NetworkMonitor;
import org.webrtc.PeerConnection;
import org.webrtc.PeerConnectionFactory;
import org.webrtc.RTCStats;
import org.webrtc.SdpObserver;
import org.webrtc.SessionDescription;

/** Android-only, data-only adapter. Signaling, files and flow control stay Dart-owned. */
final class RtcDataBridge {
    static final String CHANNEL_LABEL = "globalsend-file-v1";
    static final String PROBE_LABEL = "globalsend-probe-v1";
    static RtcNetworkPolicy sessionPolicy(String scope, boolean cellular, boolean probe) {
        return new RtcNetworkPolicy(scope, !probe && cellular);
    }
    private static final RtcRuntime runtime = new RtcRuntime();
    private final Context application;
    private final ConnectivityManager manager;
    private final MethodChannel channel;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final RtcNetworkPolicy.Owners<Session> owners = new RtcNetworkPolicy.Owners<>();
    private final Map<Boolean, PeerConnectionFactory> factories = new HashMap<>();
    private volatile boolean disposed;

    RtcDataBridge(Context context, BinaryMessenger messenger) {
        application = context.getApplicationContext();
        manager = (ConnectivityManager) application.getSystemService(Context.CONNECTIVITY_SERVICE);
        channel = new MethodChannel(messenger, "dev.globalsend/rtc");
        channel.setMethodCallHandler((call, result) -> worker.execute(() -> handle(call, new Reply(result))));
    }

    private void prepare() {
        runtime.ensure(() -> {
            // Install before the first native factory, once per process. The
            // default detector requests mobile even when a factory ignores it.
            if (NetworkMonitor.getInstance().getNumObservers() != 0) {
                throw new IllegalStateException("RTC network policy must be installed before WebRTC starts");
            }
            NetworkMonitor.getInstance().setNetworkChangeDetectorFactory(PassiveRtcNetworkDetector::new);
            // Official initialization also loads libjingle_peerconnection_so
            // and installs application ContextUtils. Never repeat it when a
            // new Activity/engine creates its own fixed-policy factories.
            PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions
                .builder(application).createInitializationOptions());
        });
    }

    private PeerConnectionFactory factory(RtcNetworkPolicy policy) {
        PeerConnectionFactory cached = factories.get(policy.cellular);
        if (cached != null) return cached;
        if (!runtime.initialized()) throw new IllegalStateException("RTC network policy is not prepared");
        PeerConnectionFactory.Options options = new PeerConnectionFactory.Options();
        options.networkIgnoreMask = policy.ignoreMask();
        // Only this bridge owns Android factories; the Flutter media plugin is
        // not initialized on Android. Global initialization stays process-owned.
        cached = PeerConnectionFactory.builder().setOptions(options).createPeerConnectionFactory();
        factories.put(policy.cellular, cached);
        return cached;
    }

    @SuppressWarnings("unchecked")
    private void handle(MethodCall call, Reply reply) {
        try {
            if (disposed) throw new IllegalStateException("RTC bridge disposed");
            if ("prepare".equals(call.method)) { prepare(); reply.success(null); return; }
            if ("revokeCellular".equals(call.method)) { owners.revokeCellular(); reply.success(null); return; }
            String id = call.argument("sessionId");
            if ("close".equals(call.method)) { owners.close(id); reply.success(null); return; }
            Session value = owners.get(id);
            if ("create".equals(call.method)) {
                if (value != null) throw new IllegalStateException("RTC session already exists");
                String scope = call.argument("scope");
                if (!"lan".equals(scope) && !"public".equals(scope)) throw new IllegalArgumentException("Unknown RTC scope");
                boolean probe = Boolean.TRUE.equals(call.argument("probe"));
                value = new Session(id, sessionPolicy(scope, Boolean.TRUE.equals(call.argument("allowCellular")), probe), probe ? PROBE_LABEL : CHANNEL_LABEL);
                owners.add(id, value);
                try { value.create(probe ? Collections.emptyList() : (List<Map<String, Object>>) call.argument("iceServers")); }
                catch (RuntimeException error) { owners.close(id); throw error; }
                reply.success(null); return;
            }
            if ("closeChannel".equals(call.method) && value == null) { reply.success(null); return; }
            if (value == null || value.closed) throw new IllegalStateException("RTC session ended");
            switch (call.method) {
                case "description": {
                    MediaConstraints constraints = new MediaConstraints();
                    constraints.mandatory.add(new MediaConstraints.KeyValuePair("OfferToReceiveAudio", "false"));
                    constraints.mandatory.add(new MediaConstraints.KeyValuePair("OfferToReceiveVideo", "false"));
                    SdpObserver observer = value.sdp(reply, true);
                    if ("offer".equals(call.argument("type"))) value.peer.createOffer(observer, constraints);
                    else if ("answer".equals(call.argument("type"))) value.peer.createAnswer(observer, constraints);
                    else throw new IllegalArgumentException("Unknown RTC description type");
                    return;
                }
                case "localDescription":
                case "remoteDescription": {
                    String sdp = call.argument("sdp"), type = call.argument("type");
                    requireDataSdp(sdp);
                    SessionDescription description = new SessionDescription(SessionDescription.Type.fromCanonicalForm(type), sdp);
                    if ("localDescription".equals(call.method)) value.peer.setLocalDescription(value.sdp(reply, false), description);
                    else value.peer.setRemoteDescription(value.sdp(reply, false), description);
                    return;
                }
                case "candidate": {
                    Number index = call.argument("sdpMLineIndex");
                    if (!value.peer.addIceCandidate(new IceCandidate(call.argument("sdpMid"), index == null ? 0 : index.intValue(), call.argument("candidate")))) {
                        throw new IllegalStateException("ICE candidate was not accepted");
                    }
                    break;
                }
                case "createChannel": {
                    if (!value.label.equals(call.argument("label"))) throw new IllegalArgumentException("Unknown data channel");
                    DataChannel.Init init = new DataChannel.Init(); init.ordered = true;
                    value.attach(value.peer.createDataChannel(value.label, init), false);
                    reply.success(value.data.state().name().toLowerCase(Locale.ROOT)); return;
                }
                case "authorize": value.requireDataPermission(); break;
                case "stats": value.stats(reply); return;
                case "bufferedAmount": reply.success(value.data.bufferedAmount()); return;
                case "send": {
                    value.requireDataPermission();
                    boolean binary = Boolean.TRUE.equals(call.argument("binary"));
                    byte[] bytes = binary ? (byte[]) call.argument("data") : ((String) call.argument("data")).getBytes(StandardCharsets.UTF_8);
                    if (bytes.length > (binary ? 16384 : 4096)) throw new IllegalArgumentException("Data frame too large");
                    if (value.data.state() != DataChannel.State.OPEN || !value.data.send(new DataChannel.Buffer(ByteBuffer.wrap(bytes), binary))) {
                        throw new IllegalStateException("Data channel could not queue frame");
                    }
                    break;
                }
                case "closeChannel": value.closeChannel(); break;
                default: reply.notImplemented(); return;
            }
            reply.success(null);
        } catch (Exception error) { reply.error(error.getMessage()); }
    }

    static void requireDataSdp(String sdp) {
        boolean application = false;
        for (String line : sdp.split("\\r?\\n")) {
            if (line.startsWith("m=application ")) application = true;
            else if (line.startsWith("m=")) throw new IllegalArgumentException("Only data-channel SDP is supported");
        }
        if (!application) throw new IllegalArgumentException("Missing data-channel SDP");
    }

    static String localAddress(String sdp) {
        String[] parts = sdp.trim().split("\\s+");
        if (parts.length < 8) return "";
        if (!"host".equals(parts[7])) {
            for (int i = 8; i + 1 < parts.length; i += 2) if ("raddr".equals(parts[i])) return parts[i + 1];
        }
        return parts[4];
    }

    static List<Map<String, Object>> statsRows(Map<String, RTCStats> stats) {
        List<Map<String, Object>> rows = new ArrayList<>();
        for (RTCStats stat : stats.values()) {
            Map<String, Object> row = map("id", stat.getId(), "type", stat.getType());
            for (String name : new String[] {"selectedCandidatePairId", "selected", "nominated", "state", "localCandidateId", "remoteCandidateId", "address", "ip", "ipAddress", "port"}) {
                Object value = stat.getMembers().get(name);
                if (value instanceof String || value instanceof Boolean || value instanceof Number) row.put(name, value instanceof Number ? ((Number) value).longValue() : value);
            }
            rows.add(row);
        }
        return rows;
    }

    private final class Session implements RtcNetworkPolicy.Owner {
        final String id;
        final RtcNetworkPolicy policy;
        final RtcNetworkPolicy.Gate gate;
        final Set<Reply> pending = ConcurrentHashMap.newKeySet();
        PeerConnection peer;
        DataChannel data;
        RtcCellularLease cellularLease;
        volatile boolean closed;
        Network selectedNetwork;
        String selectedSdp = "", family = "unknown";
        boolean remoteChannel;
        final String label;
        Session(String id, RtcNetworkPolicy policy, String label) { this.id = id; this.policy = policy; this.label = label; this.gate = new RtcNetworkPolicy.Gate(policy); }
        @Override public boolean cellular() { return policy.cellular; }

        void create(List<Map<String, Object>> servers) {
            if (policy.cellular) cellularLease = new RtcCellularLease(manager);
            List<PeerConnection.IceServer> ice = new ArrayList<>();
            for (Map<String, Object> server : servers == null ? Collections.<Map<String, Object>>emptyList() : servers) {
                Object urls = server.get("urls");
                List<String> values = new ArrayList<>();
                if (urls instanceof String) values.add((String) urls);
                else for (Object url : (List<?>) urls) values.add((String) url);
                for (String url : values) if (!url.matches("(?i)stuns?:[^\\s]+")) throw new IllegalArgumentException("Only STUN servers are supported");
                ice.add(PeerConnection.IceServer.builder(values).createIceServer());
            }
            PeerConnection.RTCConfiguration config = new PeerConnection.RTCConfiguration(ice);
            config.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN;
            config.continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY;
            peer = factory(policy).createPeerConnection(config, new PeerConnection.Observer() {
                @Override public void onSignalingChange(PeerConnection.SignalingState state) {}
                @Override public void onIceConnectionChange(PeerConnection.IceConnectionState state) {}
                @Override public void onIceConnectionReceivingChange(boolean receiving) {}
                @Override public void onIceGatheringChange(PeerConnection.IceGatheringState state) {}
                @Override public void onIceCandidatesRemoved(IceCandidate[] candidates) {}
                @Override public void onAddStream(MediaStream stream) {}
                @Override public void onRemoveStream(MediaStream stream) {}
                @Override public void onRenegotiationNeeded() {}
                @Override public void onConnectionChange(PeerConnection.PeerConnectionState state) {
                    emit("connection", map("state", state.name().toLowerCase(Locale.ROOT)), false);
                }
                @Override public void onIceCandidate(IceCandidate candidate) {
                    emit("candidate", map("candidate", map("candidate", candidate.sdp, "sdpMid", candidate.sdpMid, "sdpMLineIndex", candidate.sdpMLineIndex)), false);
                }
                @Override public void onSelectedCandidatePairChanged(CandidatePairChangeEvent event) {
                    execute(() -> {
                        if (closed) return;
                        selectedSdp = event.local.sdp;
                        selectedNetwork = networkForAddress(localAddress(selectedSdp));
                        String[] parts = selectedSdp.split("\\s+");
                        family = parts.length > 4 && parts[4].contains(":") ? "ipv6" : "ipv4";
                        try { requireDataPermission(); }
                        catch (RuntimeException error) { fail(error.getMessage()); }
                    });
                }
                @Override public void onDataChannel(DataChannel channel) { execute(() -> {
                    if (closed) { channel.close(); channel.dispose(); return; }
                    try { attach(channel, true); } catch (RuntimeException error) { fail(error.getMessage()); }
                }); }
            });
            if (peer == null) throw new IllegalStateException("Unable to create WebRTC data connection");
        }

        Network networkForAddress(String address) {
            if (!address.matches("[0-9a-fA-F:.%a-zA-Z0-9_-]+") || !address.contains(":") && !address.matches("[0-9.]+")) return null;
            try {
                InetAddress ip = InetAddress.getByName(address.split("%", 2)[0]);
                Network matched = null;
                for (Network network : manager.getAllNetworks()) {
                    LinkProperties properties = manager.getLinkProperties(network);
                    if (properties == null) continue;
                    for (LinkAddress local : properties.getLinkAddresses()) if (local.getAddress().equals(ip)) {
                        matched = network;
                        String kind = PassiveRtcNetworkDetector.networkKind(manager.getNetworkCapabilities(network));
                        if ("cellular".equals(kind) || "vpn".equals(kind)) return network;
                    }
                }
                return matched;
            } catch (java.net.UnknownHostException error) { return null; }
        }

        void requireDataPermission() {
            String kind = selectedNetwork == null ? "unknown"
                : PassiveRtcNetworkDetector.networkKind(manager.getNetworkCapabilities(selectedNetwork));
            // A missing/ambiguous local mapping is not proof of Wi-Fi. Gate
            // both receiver ready and source payload, and recheck on sends.
            gate.selected(!selectedSdp.isEmpty(), kind);
            gate.requireFrame();
            if (gate.reportChanged(kind, family)) {
                emit("network", map("network", kind, "family", family), false);
            }
        }

        SdpObserver sdp(Reply reply, boolean creating) {
            pending.add(reply);
            return new SdpObserver() {
                private void finish(Object result, String error) {
                    pending.remove(reply);
                    if (error == null) reply.success(result); else reply.error(error);
                }
                @Override public void onCreateSuccess(SessionDescription value) {
                    if (creating) finish(map("type", value.type.canonicalForm(), "sdp", value.description), null);
                }
                @Override public void onSetSuccess() { if (!creating) finish(null, null); }
                @Override public void onCreateFailure(String error) { finish(null, error); }
                @Override public void onSetFailure(String error) { finish(null, error); }
            };
        }

        void stats(Reply reply) {
            pending.add(reply);
            peer.getStats(report -> execute(() -> {
                if (closed) return;
                pending.remove(reply);
                reply.success(statsRows(report.getStatsMap()));
            }));
        }

        void attach(DataChannel value, boolean remote) {
            if (data != null || !label.equals(value.label())) {
                value.close(); value.dispose();
                throw new IllegalStateException("Unexpected data channel");
            }
            data = value; remoteChannel = remote;
            value.registerObserver(new DataChannel.Observer() {
                @Override public void onBufferedAmountChange(long previous) {}
                @Override public void onStateChange() { execute(() -> { if (!closed && data == value) emitState(); }); }
                @Override public void onMessage(DataChannel.Buffer buffer) {
                    int length = buffer.data.remaining();
                    if (length > (buffer.binary ? 16384 : 4096)) { execute(() -> fail("Data frame too large")); return; }
                    byte[] bytes = new byte[length]; buffer.data.get(bytes);
                    execute(() -> {
                        if (closed) return;
                        try {
                            requireDataPermission();
                            emit("message", map("binary", buffer.binary,
                                "data", buffer.binary ? bytes : new String(bytes, StandardCharsets.UTF_8)), false);
                        } catch (RuntimeException error) { fail(error.getMessage()); }
                    });
                }
            });
            emitState();
        }
        void emitState() {
            if (data != null) emit("channel", map("label", data.label(),
                "state", data.state().name().toLowerCase(Locale.ROOT), "remote", remoteChannel), false);
        }
        void emit(String type, Map<String, Object> values, boolean terminal) {
            Map<String, Object> event = map("sessionId", id, "type", type); event.putAll(values);
            main.post(() -> { if (!disposed && (terminal || !closed)) channel.invokeMethod("event", event); });
        }
        void fail(String message) {
            if (closed) return;
            emit("connection", map("state", "failed", "error", message), true);
            owners.close(id);
        }
        void closeChannel() {
            if (data != null) {
                data.unregisterObserver(); data.close(); data.dispose(); data = null;
            }
        }
        @Override public void close() {
            if (closed) return;
            closed = true;
            try {
                for (Reply reply : pending) reply.error("RTC session ended");
                pending.clear();
                try { closeChannel(); }
                finally { if (peer != null) { peer.dispose(); peer = null; } }
            } finally {
                if (cellularLease != null) { cellularLease.close(); cellularLease = null; }
            }
        }
    }

    private void execute(Runnable value) { if (!disposed) worker.execute(value); }
    private final class Reply {
        final MethodChannel.Result result;
        final AtomicBoolean sent = new AtomicBoolean();
        Reply(MethodChannel.Result result) { this.result = result; }
        void success(Object value) { if (sent.compareAndSet(false, true)) main.post(() -> result.success(value)); }
        void error(String error) { if (sent.compareAndSet(false, true)) main.post(() -> result.error("RTC_FAILED", error, null)); }
        void notImplemented() { if (sent.compareAndSet(false, true)) main.post(result::notImplemented); }
    }
    static Map<String, Object> map(Object... values) {
        Map<String, Object> result = new HashMap<>();
        for (int i = 0; i < values.length; i += 2) result.put((String) values[i], values[i + 1]);
        return result;
    }
    void dispose() {
        if (disposed) return;
        disposed = true; channel.setMethodCallHandler(null);
        try {
            // Complete this engine's ownership handoff; process-global runtime
            // initialization remains intact for the next engine.
            worker.submit(() -> {
                try { owners.closeAll(); }
                finally { for (PeerConnectionFactory value : factories.values()) value.dispose(); factories.clear(); }
            }).get();
        } catch (Exception error) { throw new IllegalStateException("Unable to close RTC owners", error); }
        finally { worker.shutdown(); }
    }
}
