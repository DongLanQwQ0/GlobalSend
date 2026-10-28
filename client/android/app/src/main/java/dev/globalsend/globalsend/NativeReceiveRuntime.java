package dev.globalsend.globalsend;

import android.content.Context;
import android.app.Activity;
import android.os.Handler;
import android.os.Build;
import android.os.Looper;
import io.flutter.embedding.engine.dart.DartExecutor;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import androidx.annotation.NonNull;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.os.SystemClock;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import java.util.List;
import java.security.MessageDigest;
import java.security.cert.X509Certificate;
import java.security.cert.CertificateException;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;
import org.json.JSONObject;
import io.flutter.plugin.common.MethodCall;

final class NativeReceiveRuntime {
    private static NativeReceiveRuntime instance;
    static synchronized NativeReceiveRuntime ensure(Context context) {
        if (instance == null) instance = new NativeReceiveRuntime(context.getApplicationContext());
        return instance;
    }
    static NativeReceiveRuntime current() { return instance; }
    final FlutterEngine engine;
    final Context context;
    final Handler main = new Handler(Looper.getMainLooper());
    final long createdAt = SystemClock.elapsedRealtime();
    final BackgroundReceiveBridge background;
    private java.lang.ref.WeakReference<MainActivity> attachedActivity = new java.lang.ref.WeakReference<>(null);
    private static final String CONNECTIVITY_SERVICE = Context.CONNECTIVITY_SERVICE;
    private NativeReceiveRuntime(Context context) {
        this.context = context;
        engine = new FlutterEngine(context);
        installChannels();
        background = new BackgroundReceiveBridge(this, engine.getDartExecutor().getBinaryMessenger());
        engine.getDartExecutor().executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault());
    }
    private Object getSystemService(String name) { return context.getSystemService(name); }
    private void runOnUiThread(Runnable work) { main.post(work); }
    void attach(MainActivity activity) {
        attachedActivity = new java.lang.ref.WeakReference<>(activity);
        dockCoordinator.attach(activity); receiveDirectory.attach(activity); receivedNotifications.attach(activity);
        background.attach(activity);
    }
    void detach(MainActivity activity) {
        if (attachedActivity.get() == activity) attachedActivity.clear();
        dockCoordinator.detach(activity); receiveDirectory.detach(activity); receivedNotifications.detach(activity);
        background.detach(activity);
    }
    void resumed() { dockCoordinator.resumed(); }
    void visible(Activity activity, boolean foreground) { receivedNotifications.visible(activity, foreground); }
    void presentationRejected(boolean rejected) { receivedNotifications.presentationRejected(rejected); }
    void presentationResult(MainActivity activity, String id, boolean converted, boolean resumed) {
        if (attachedActivity.get() == activity) receivedNotifications.presentationResult(id, converted, resumed);
    }
    void presentationChanged(boolean floating) {
        java.util.Map<String, Object> state = new java.util.HashMap<>();
        state.put("floating", floating);
        state.put("arrivalGeneration", receivedNotifications.arrivalGeneration());
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "dev.globalsend/system")
            .invokeMethod("receiptPresentationChanged", state);
    }
    void intent(android.content.Intent intent) { if (!fileShare.handleIntent(intent)) dockCoordinator.handleSharedIntent(intent); receivedNotifications.opened(intent); }
    boolean activityResult(int requestCode,int resultCode,android.content.Intent data) {
        return dockCoordinator.onActivityResult(requestCode,resultCode,data) || receiveDirectory.onActivityResult(requestCode,resultCode,data);
    }
    void permissionChanged() { receivedNotifications.permissionChanged(); }
    private DockCoordinator dockCoordinator;
    private FileShareBridge fileShare;
    private ReceiveDirectory receiveDirectory;
    private RtcDataBridge rtcDataBridge;
    private ReceiveNotificationBridge receivedNotifications;
    private final ExecutorService transfers = Executors.newFixedThreadPool(16);
    private final ExecutorService connectionChecks = peerProbeExecutor();
    static ExecutorService peerProbeExecutor() {
        // Dart races all candidate pairs under one decision deadline. Queuing a
        // working address behind stalled Network/TLS handshakes makes that race
        // incorrectly fall back to relay. Idle workers are reclaimed by the pool.
        return Executors.newCachedThreadPool();
    }
    private final java.util.concurrent.ScheduledExecutorService writeTimeouts = Executors.newSingleThreadScheduledExecutor();
    private final java.util.concurrent.ConcurrentHashMap<String, HttpsURLConnection> activeDownloads = new java.util.concurrent.ConcurrentHashMap<>();
    private final java.util.Set<String> canceled = java.util.concurrent.ConcurrentHashMap.newKeySet();
    private final java.util.concurrent.ConcurrentHashMap<String, Runnable> activeProbeCancellations = new java.util.concurrent.ConcurrentHashMap<>();
    private void installChannels() {
        dockCoordinator = new DockCoordinator(context, new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "dev.globalsend/dock"));
        fileShare = new FileShareBridge(context,new MethodChannel(engine.getDartExecutor().getBinaryMessenger(),"dev.globalsend/share"),()->attachedActivity.get());
        receiveDirectory = new ReceiveDirectory(context, engine);
        rtcDataBridge = new RtcDataBridge(context, engine.getDartExecutor().getBinaryMessenger());
        receivedNotifications = new ReceiveNotificationBridge(context, engine.getDartExecutor().getBinaryMessenger());
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "dev.globalsend/system").setMethodCallHandler((call, result) -> {
            if ("deviceName".equals(call.method)) result.success(AndroidDeviceName.read(context));
            else if ("localIpInterfaces".equals(call.method)) {
                try { result.success(LocalIpInterfaces.read(context)); }
                catch (java.net.SocketException error) { result.error("IP_INTERFACES", "无法读取网卡地址", null); }
            }
            else if ("beginReceivedWindowGesture".equals(call.method) || "endReceivedWindowGesture".equals(call.method)) {
                MainActivity activity = attachedActivity.get();
                Number downTime = call.argument("downTimeMillis");
                result.success(activity != null && downTime != null &&
                    ("beginReceivedWindowGesture".equals(call.method)
                        ? activity.beginReceivedWindowGesture(downTime.longValue(), Boolean.TRUE.equals(call.argument("resize")))
                        : activity.endReceivedWindowGesture(downTime.longValue())));
            }
            else if ("adjustReceivedWindow".equals(call.method)) {
                MainActivity activity = attachedActivity.get();
                Number dx = call.argument("dx"), dy = call.argument("dy");
                Number dw = call.argument("dw"), dh = call.argument("dh");
                result.success(activity != null && activity.adjustReceivedWindow(
                    dx == null ? 0 : dx.floatValue(), dy == null ? 0 : dy.floatValue(),
                    dw == null ? 0 : dw.floatValue(), dh == null ? 0 : dh.floatValue()));
            }
            else if ("receivedWindowState".equals(call.method)) {
                MainActivity activity = attachedActivity.get();
                java.util.Map<String, Object> state = new java.util.HashMap<>();
                state.put("floating", false);
                state.put("supported", false);
                state.put("arrivalGeneration", receivedNotifications.arrivalGeneration());
                result.success(state);
            }
            else if ("expandReceivedWindow".equals(call.method) || "dismissReceivedWindow".equals(call.method)) {
                MainActivity activity = attachedActivity.get();
                Number expected = call.argument("arrivalGeneration");
                boolean success = activity == null || ("expandReceivedWindow".equals(call.method)
                    ? activity.expandReceivedWindow()
                    : receivedNotifications.dismissIfCurrent(expected == null ? null : expected.longValue(), activity::dismissReceivedWindow));
                if (success) result.success(null);
                else result.error("WINDOW_PRESENTATION_FAILED", "系统未能恢复窗口", null);
            }
            else if ("openWebUrl".equals(call.method)) {
                try {
                    android.net.Uri uri = android.net.Uri.parse(call.argument("url"));
                    if (!("https".equals(uri.getScheme()) || "http".equals(uri.getScheme())) || uri.getHost() == null)
                        throw new IllegalArgumentException("网址无效");
                    context.startActivity(new android.content.Intent(android.content.Intent.ACTION_VIEW, uri)
                        .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK));
                    result.success(null);
                } catch (Exception error) { result.error("OPEN_URL_FAILED", "无法打开网址", null); }
            }
            else result.notImplemented();
        });
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "dev.globalsend/vault").setMethodCallHandler((call, result) -> {
            try {
                if (!call.method.equals("seal") && !call.method.equals("unseal")) { result.notImplemented(); return; }
                java.security.KeyStore store = java.security.KeyStore.getInstance("AndroidKeyStore"); store.load(null);
                String alias = "GlobalSendVault";
                if (!store.containsAlias(alias)) {
                    javax.crypto.KeyGenerator generator = javax.crypto.KeyGenerator.getInstance("AES", "AndroidKeyStore");
                    generator.init(new android.security.keystore.KeyGenParameterSpec.Builder(alias, android.security.keystore.KeyProperties.PURPOSE_ENCRYPT | android.security.keystore.KeyProperties.PURPOSE_DECRYPT)
                        .setBlockModes(android.security.keystore.KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(android.security.keystore.KeyProperties.ENCRYPTION_PADDING_NONE).build()); generator.generateKey();
                }
                javax.crypto.SecretKey key = (javax.crypto.SecretKey) store.getKey(alias, null);
                javax.crypto.Cipher cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding");
                byte[] input = (byte[]) call.arguments;
                if (call.method.equals("seal")) {
                    cipher.init(javax.crypto.Cipher.ENCRYPT_MODE, key); byte[] encrypted = cipher.doFinal(input);
                    byte[] output = new byte[12 + encrypted.length]; System.arraycopy(cipher.getIV(), 0, output, 0, 12); System.arraycopy(encrypted, 0, output, 12, encrypted.length); result.success(output);
                } else {
                    if (input.length < 28) throw new IllegalArgumentException("Invalid protected credential");
                    cipher.init(javax.crypto.Cipher.DECRYPT_MODE, key, new javax.crypto.spec.GCMParameterSpec(128, input, 0, 12));
                    result.success(cipher.doFinal(input, 12, input.length - 12));
                }
            } catch (Exception e) { result.error("VAULT_FAILED", "System credential protection failed", null); }
        });
        MethodChannel channel = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "dev.globalsend/network");
        channel.setMethodCallHandler((call, result) -> {
                if (call.method.equals("cancelOperation")) { String id = call.argument("operationId"); canceled.add(id); HttpsURLConnection active = activeDownloads.get(id); if (active != null) active.disconnect(); Runnable stop = activeProbeCancellations.remove(id); if (stop != null) stop.run(); result.success(null); return; }
                if (!call.method.equals("probe") && !call.method.equals("probePeer") && !call.method.equals("putFile") && !call.method.equals("downloadPeer") && !call.method.equals("uploadPeer")) { result.notImplemented(); return; }
                (call.method.equals("probePeer") ? connectionChecks : transfers).execute(() -> {
                    ConnectivityManager manager = (ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
                    ConnectivityManager.NetworkCallback callback = null;
                    HttpURLConnection connection = null;
                    // Transfers need the same cancellable cellular acquisition
                    // as probes, before any socket or file writer exists.
                    String probeOperation = call.argument("operationId");
                    java.util.concurrent.atomic.AtomicBoolean probeNetworkReleased = new java.util.concurrent.atomic.AtomicBoolean();
                    long operationStarted = SystemClock.elapsedRealtime();
                    try {
                        if (probeOperation != null && canceled.contains(probeOperation)) throw new InterruptedException("Probe canceled");
                        URL url = new URL(call.method.equals("downloadPeer") || call.method.equals("probePeer") || call.method.equals("uploadPeer") ? "https://localhost" : (String) call.argument("url"));
                        if (!url.getProtocol().equals("https") || url.getUserInfo() != null) throw new IllegalArgumentException("Only HTTPS is supported");
                        boolean cellular = Boolean.TRUE.equals(call.argument("cellular"));
                        Network network;
                        if (cellular) {
                            CountDownLatch latch = new CountDownLatch(1);
                            AtomicReference<Network> selected = new AtomicReference<>();
                            callback = new ConnectivityManager.NetworkCallback() {
                                @Override public void onAvailable(@NonNull Network value) { selected.compareAndSet(null, value); latch.countDown(); }
                                @Override public void onUnavailable() { latch.countDown(); }
                            };
                            manager.requestNetwork(new NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR).addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build(), callback, 10000);
                            if (probeOperation != null) {
                                final ConnectivityManager.NetworkCallback probeCallback = callback;
                                Runnable stop = () -> {
                                    if (probeNetworkReleased.compareAndSet(false, true)) {
                                        try { manager.unregisterNetworkCallback(probeCallback); } catch (IllegalArgumentException ignored) {}
                                    }
                                    latch.countDown();
                                };
                                activeProbeCancellations.put(probeOperation, stop);
                                if (canceled.contains(probeOperation)) stop.run();
                            }
                            latch.await(11, TimeUnit.SECONDS);
                            if (probeOperation != null && canceled.contains(probeOperation)) throw new InterruptedException("Probe canceled");
                            network = selected.get();
                            if (network == null) throw new IllegalStateException("Cellular network unavailable");
                        } else {
                            network = manager.getActiveNetwork();
                            if (network == null) throw new IllegalStateException("No active network");
                        }
                        long started = SystemClock.elapsedRealtime();
                        if (call.method.equals("probePeer")) {
                            Map<String, Object> value = probePeer(network, call);
                            value.put("network", cellular ? "cellular" : "default");
                            runOnUiThread(() -> result.success(value)); return;
                        }
                        if (call.method.equals("downloadPeer")) {
                            Map<String, Object> value = downloadPeer(network, call, channel);
                            value.put("networkHandle", network.getNetworkHandle()); value.put("network", cellular ? "cellular" : "default");
                            runOnUiThread(() -> result.success(value)); return;
                        }
                        if (call.method.equals("uploadPeer")) {
                            Map<String, Object> value = uploadPeer(network, call, channel);
                            value.put("networkHandle", network.getNetworkHandle()); value.put("network", cellular ? "cellular" : "default");
                            runOnUiThread(() -> result.success(value)); return;
                        }
                        // openConnection resolves DNS and binds this socket on the selected Network.
                        // No process-wide network binding and no custom trust manager.
                        connection = (HttpURLConnection) network.openConnection(url);
                        connection.setInstanceFollowRedirects(false);
                        connection.setConnectTimeout(10000);
                        connection.setReadTimeout(30000);
                        long bytes = 0;
                        if (call.method.equals("putFile")) {
                            String path = call.argument("path");
                            Number start = call.argument("offset"), requested = call.argument("length");
                            long offset = start == null ? 0 : start.longValue();
                            long length = requested == null ? 0 : requested.longValue();
                            if (offset < 0 || length < 0 || length > 1048576) throw new IllegalArgumentException("Invalid chunk bounds");
                            connection.setRequestMethod("PUT"); connection.setDoOutput(true);
                            connection.setFixedLengthStreamingMode(length);
                            connection.setRequestProperty("Content-Type", "application/octet-stream");
                            String auth = call.argument("authorization");
                            if (auth != null && !auth.isEmpty()) connection.setRequestProperty("Authorization", auth);
                            try (AndroidReadSource file = new AndroidReadSource(context, path)) {
                                if (offset + length > file.length()) throw new IllegalArgumentException("Source file changed");
                                file.seek(offset);
                                try (OutputStream output = connection.getOutputStream()) {
                                    byte[] buffer = new byte[65536];
                                    while (bytes < length) {
                                        int count = file.read(buffer, 0, (int) Math.min(buffer.length, length - bytes));
                                        if (count < 0) throw new IllegalStateException("Unexpected end of file");
                                        output.write(buffer, 0, count); bytes += count;
                                    }
                                }
                            }
                        }
                        int status = connection.getResponseCode();
                        if (status < 200 || status >= 300) throw new IllegalStateException("HTTP " + status);
                        try (java.io.InputStream input = connection.getInputStream()) { byte[] b = new byte[4096]; while (input.read(b) != -1) {} }
                        Map<String, Object> value = new HashMap<>();
                        value.put("status", status); value.put("networkHandle", network.getNetworkHandle());
                        value.put("network", cellular ? "cellular" : "default"); value.put("elapsedMs", SystemClock.elapsedRealtime() - started); value.put("bytes", bytes);
                        runOnUiThread(() -> result.success(value));
                    } catch (Exception error) {
                        String message = error.getClass().getSimpleName() + ": " + error.getMessage();
                        if (call.method.equals("probePeer")) {
                            Map<String, Object> value = new HashMap<>();
                            value.put("reachable", false); value.put("error", message);
                            value.put("elapsedMs", SystemClock.elapsedRealtime() - operationStarted);
                            value.put("network", Boolean.TRUE.equals(call.argument("cellular")) ? "cellular" : "default");
                            runOnUiThread(() -> result.success(value));
                        } else {
                            runOnUiThread(() -> result.error("NETWORK_FAILED", message, null));
                        }
                    } finally {
                        if (connection != null) connection.disconnect();
                        if (callback != null && (probeOperation == null || probeNetworkReleased.compareAndSet(false, true))) { try { manager.unregisterNetworkCallback(callback); } catch (Exception ignored) {} }
                        if (probeOperation != null) { activeProbeCancellations.remove(probeOperation); canceled.remove(probeOperation); }
                    }
                });
            });
    }
    private static String fingerprint(X509Certificate certificate) throws Exception {
        byte[] bytes = MessageDigest.getInstance("SHA-256").digest(certificate.getEncoded());
        StringBuilder value = new StringBuilder(); for (byte b : bytes) value.append(String.format("%02x", b & 255)); return value.toString();
    }
    private HttpsURLConnection pinned(Network network, URL url, String expected) throws Exception {
        if (!url.getProtocol().equals("https") || url.getUserInfo() != null || !expected.matches("[a-f0-9]{64}")) throw new IllegalArgumentException("Invalid peer identity");
        TrustManager[] managers = new TrustManager[] { new X509TrustManager() {
            @Override public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            @Override public void checkClientTrusted(X509Certificate[] chain, String type) throws CertificateException { throw new CertificateException("Not a client endpoint"); }
            @Override public void checkServerTrusted(X509Certificate[] chain, String type) throws CertificateException {
                try { if (chain.length == 0 || !fingerprint(chain[0]).equals(expected)) throw new CertificateException("Peer fingerprint mismatch"); chain[0].checkValidity(); }
                catch (CertificateException e) { throw e; } catch (Exception e) { throw new CertificateException(e); }
            }
        }};
        SSLContext tls = SSLContext.getInstance("TLS"); tls.init(null, managers, null);
        HttpsURLConnection connection = (HttpsURLConnection) network.openConnection(url);
        connection.setSSLSocketFactory(tls.getSocketFactory());
        connection.setHostnameVerifier((hostname, session) -> { try { return fingerprint((X509Certificate) session.getPeerCertificates()[0]).equals(expected); } catch (Exception e) { return false; } });
        connection.setInstanceFollowRedirects(false); connection.setConnectTimeout(3000); connection.setReadTimeout(20000);
        return connection;
    }
    private Map<String, Object> probePeer(Network network, MethodCall call) throws Exception {
        String candidate = call.argument("candidate"), expected = call.argument("fingerprint"), nonce = call.argument("nonce");
        String operation = call.argument("operationId");
        URL base = new URL(candidate);
        if ((!base.getPath().isEmpty() && !base.getPath().equals("/")) || base.getQuery() != null || base.getRef() != null) {
            throw new IllegalArgumentException("Invalid peer address");
        }
        long started = SystemClock.elapsedRealtime();
        HttpsURLConnection probe = pinned(network, new URL(base, "/probe?nonce=" + java.net.URLEncoder.encode(nonce, "UTF-8")), expected);
        ObservedTlsSocketFactory observed = new ObservedTlsSocketFactory(probe.getSSLSocketFactory());
        probe.setSSLSocketFactory(observed);
        probe.setConnectTimeout(2000); probe.setReadTimeout(2000);
        if (operation != null) activeDownloads.put(operation, probe);
        try {
            if (operation != null && canceled.contains(operation)) throw new InterruptedException("Probe canceled");
            int status = probe.getResponseCode();
            if (status != 200) throw new IllegalStateException("HTTP " + status);
            Map<String, Object> endpoints = observed.endpoints();
            java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
            try (java.io.InputStream input = probe.getInputStream()) {
                byte[] buffer = new byte[1024]; int count;
                while ((count = input.read(buffer)) != -1) {
                    out.write(buffer, 0, count);
                    if (out.size() > 4096) throw new IllegalStateException("Invalid probe response");
                    if (SystemClock.elapsedRealtime() - started > 4000) throw new java.net.SocketTimeoutException("Peer probe timed out");
                }
            }
            JSONObject reply = new JSONObject(out.toString("UTF-8"));
            if (!reply.getString("nonce").equals(nonce) || !reply.getString("certificateSha256").equals(expected)) {
                throw new IllegalStateException("Peer identity mismatch");
            }
            Map<String, Object> value = new HashMap<>();
            value.put("reachable", true); value.put("elapsedMs", SystemClock.elapsedRealtime() - started);
            value.putAll(endpoints);
            return value;
        } finally { if (operation != null) activeDownloads.remove(operation, probe); probe.disconnect(); }
    }
    private Map<String, Object> downloadPeer(Network network, MethodCall call, MethodChannel channel) throws Exception {
        List<String> candidates = call.argument("candidates");
        String expected = call.argument("fingerprint"), nonce = call.argument("nonce");
        String operation = call.argument("operationId");
        String chosen = verifiedCandidate(call, candidates);
        long probeDeadline = SystemClock.elapsedRealtime() + 7000;
        // Probe and file socket both use this exact Network instance.
        for (String candidate : candidates) {
            if (chosen != null) break;
            if (canceled.contains(operation)) throw new InterruptedException();
            int remaining = (int) (probeDeadline - SystemClock.elapsedRealtime());
            if (remaining <= 0) break;
            HttpsURLConnection probe = null;
            try {
                URL base = new URL(candidate);
                if (!base.getPath().isEmpty() && !base.getPath().equals("/")) continue;
                if (base.getQuery() != null || base.getRef() != null) continue;
                probe = pinned(network, new URL(base, "/probe?nonce=" + nonce), expected);
                activeDownloads.put(operation, probe);
                probe.setConnectTimeout(Math.min(1500, remaining));
                probe.setReadTimeout(Math.min(1500, remaining));
                if (probe.getResponseCode() != 200) continue;
                java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
                try (java.io.InputStream input = probe.getInputStream()) {
                    byte[] buffer = new byte[1024]; int n;
                    while ((n = input.read(buffer)) != -1) { if (SystemClock.elapsedRealtime() > probeDeadline || canceled.contains(operation)) throw new InterruptedException(); out.write(buffer, 0, n); if (out.size() > 4096) throw new IllegalStateException("Invalid probe"); }
                }
                JSONObject json = new JSONObject(out.toString("UTF-8"));
                if (!json.getString("nonce").equals(nonce) || !json.getString("certificateSha256").equals(expected)) continue;
                chosen = candidate; break;
            } catch (Exception ignored) {} finally { activeDownloads.remove(operation); if (probe != null) probe.disconnect(); }
        }
        if (chosen == null) throw new IllegalStateException("No reachable pinned peer over cellular");
        String transfer = call.argument("transferId"), fileId = call.argument("fileId");
        Number expectedSizeValue = call.argument("expectedSize"); long expectedSize = expectedSizeValue.longValue();
        String expectedHash = call.argument("expectedSha256");
        if (!transfer.matches("[a-zA-Z0-9_-]{1,100}") || !fileId.matches("[a-zA-Z0-9_-]{1,100}")) throw new IllegalArgumentException("Invalid transfer ID");
        HttpsURLConnection connection = pinned(network, new URL(new URL(chosen), "/files/" + transfer + "/" + fileId), expected);
        connection.setRequestProperty("X-GlobalSend-Ticket", (String) call.argument("ticket"));
        java.io.File outputFile = new java.io.File((String) call.argument("path"));
        long offset = outputFile.exists() ? outputFile.length() : 0;
        if (offset > expectedSize) offset = 0;
        if (offset > 0) { connection.setRequestProperty("Range", "bytes=" + offset + "-"); connection.setRequestProperty("If-Range", "\"sha256-" + expectedHash + "\""); }
        activeDownloads.put(operation, connection);
        long count = offset, last = 0;
        try {
            int status = connection.getResponseCode();
            if (status == 416 && offset == expectedSize) { Map<String,Object> done = new HashMap<>(); done.put("bytes",offset); return done; }
            if (status == 206) {
                String expectedRange = "bytes " + offset + "-" + (expectedSize - 1) + "/" + expectedSize;
                if (!expectedRange.equals(connection.getHeaderField("Content-Range")) || !("\"sha256-" + expectedHash + "\"").equals(connection.getHeaderField("ETag"))) throw new IllegalStateException("Peer resume response mismatch");
            } else if (status == 200) { offset = 0; count = 0; } else throw new IllegalStateException("Peer authorization failed");
            try (java.io.InputStream input = connection.getInputStream(); java.io.FileOutputStream output = new java.io.FileOutputStream(outputFile, offset > 0)) {
                byte[] buffer = new byte[65536]; int n;
                while ((n = input.read(buffer)) != -1) {
                    if (Thread.currentThread().isInterrupted() || canceled.contains(operation)) throw new InterruptedException();
                    if (count + n > expectedSize) throw new IllegalStateException("Peer sent more bytes than offered");
                    output.write(buffer, 0, n); count += n;
                    if (SystemClock.elapsedRealtime() - last > 150) {
                        last = SystemClock.elapsedRealtime(); final long progress = count;
                        runOnUiThread(() -> { Map<String, Object> data = new HashMap<>(); data.put("operationId", operation); data.put("bytes", progress); channel.invokeMethod("progress", data); });
                    }
                }
                output.getFD().sync();
            }
        } finally { activeDownloads.remove(operation); canceled.remove(operation); connection.disconnect(); }
        Map<String, Object> result = new HashMap<>(); result.put("bytes", count); return result;
    }
    private Map<String, Object> uploadPeer(Network network, MethodCall call, MethodChannel channel) throws Exception {
        List<String> candidates = call.argument("candidates");
        String expected = call.argument("fingerprint"), nonce = call.argument("nonce"), operation = call.argument("operationId");
        String chosen = verifiedCandidate(call, candidates), lastError = "No candidate";
        long deadline = SystemClock.elapsedRealtime() + 7000;
        for (String candidate : candidates) {
            if (chosen != null) break;
            if (canceled.contains(operation)) throw new InterruptedException("Upload canceled");
            if (SystemClock.elapsedRealtime() >= deadline) break;
            try {
                Map<String, Object> arguments = new HashMap<>();
                arguments.put("candidate", candidate); arguments.put("fingerprint", expected); arguments.put("nonce", nonce);
                probePeer(network, new MethodCall("probePeer", arguments));
                chosen = candidate; break;
            } catch (Exception error) { lastError = error.getClass().getSimpleName() + ": " + error.getMessage(); }
        }
        if (chosen == null) throw new IllegalStateException("No reachable pinned receiver: " + lastError);
        if (canceled.contains(operation)) throw new InterruptedException("Upload canceled");
        String transfer = call.argument("transferId"), fileId = call.argument("fileId"), attempt = call.argument("attemptId");
        if (!transfer.matches("[a-zA-Z0-9_-]{1,100}") || !fileId.matches("[a-zA-Z0-9_-]{1,100}") || !attempt.matches("[a-zA-Z0-9_-]{1,100}")) throw new IllegalArgumentException("Invalid transfer identity");
        long size = ((Number) call.argument("expectedSize")).longValue(), offset = ((Number) call.argument("offset")).longValue();
        if (offset < 0 || offset > size) throw new IllegalArgumentException("Invalid upload offset");
        HttpsURLConnection connection = pinned(network, new URL(new URL(chosen), "/push/" + transfer + "/" + fileId + "/" + attempt), expected);
        connection.setRequestMethod("PUT"); connection.setDoOutput(true); connection.setFixedLengthStreamingMode(size - offset);
        connection.setRequestProperty("Content-Type", "application/octet-stream");
        connection.setRequestProperty("X-GlobalSend-Ticket", (String) call.argument("ticket"));
        activeDownloads.put(operation, connection);
        java.util.concurrent.atomic.AtomicLong activity = new java.util.concurrent.atomic.AtomicLong(SystemClock.elapsedRealtime());
        java.util.concurrent.ScheduledFuture<?> timeout = writeTimeouts.scheduleAtFixedRate(() -> {
            if (SystemClock.elapsedRealtime() - activity.get() > 20000) connection.disconnect();
        }, 2, 2, TimeUnit.SECONDS);
        long count = offset, last = 0;
        try (AndroidReadSource source = new AndroidReadSource(context, (String) call.argument("path"))) {
            if (source.length() != size) throw new IllegalStateException("Source file changed");
            source.seek(offset);
            try (OutputStream output = connection.getOutputStream()) {
                byte[] buffer = new byte[65536];
                while (count < size) {
                    if (canceled.contains(operation) || Thread.currentThread().isInterrupted()) throw new InterruptedException("Upload canceled");
                    int n = source.read(buffer, 0, (int) Math.min(buffer.length, size - count));
                    if (n < 0) throw new IllegalStateException("Unexpected end of source file");
                    output.write(buffer, 0, n); count += n; activity.set(SystemClock.elapsedRealtime());
                    if (SystemClock.elapsedRealtime() - last > 150 || count == size) {
                        last = SystemClock.elapsedRealtime(); final long progress = count;
                        runOnUiThread(() -> { Map<String, Object> data = new HashMap<>(); data.put("operationId", operation); data.put("bytes", progress); channel.invokeMethod("progress", data); });
                    }
                }
            }
            int status = connection.getResponseCode();
            if (status != 200) throw new IllegalStateException("Peer upload HTTP " + status);
            java.io.ByteArrayOutputStream body = new java.io.ByteArrayOutputStream();
            try (java.io.InputStream input = connection.getInputStream()) {
                byte[] buffer = new byte[1024]; int n;
                while ((n = input.read(buffer)) != -1) { body.write(buffer, 0, n); if (body.size() > 4096) throw new IllegalStateException("Invalid upload response"); }
            }
            JSONObject reply = new JSONObject(body.toString("UTF-8"));
            if (reply.getLong("bytes") != size || !attempt.equals(reply.getString("attemptId"))) throw new IllegalStateException("Peer upload response mismatch");
            Map<String, Object> result = new HashMap<>(); result.put("bytes", count); return result;
        } finally {
            timeout.cancel(false); activeDownloads.remove(operation); canceled.remove(operation); connection.disconnect();
        }
    }

    // The Dart planner already checked this endpoint on cellular. Keep TLS pin
    // validation on the file socket, without doing a second nonce handshake.
    private static String verifiedCandidate(MethodCall call, List<String> candidates) throws Exception {
        String value = call.argument("verifiedCandidate");
        if (value == null) return null;
        URL base = new URL(value);
        if (!candidates.contains(value) || !"https".equals(base.getProtocol()) ||
                base.getUserInfo() != null || base.getQuery() != null || base.getRef() != null ||
                (!base.getPath().isEmpty() && !"/".equals(base.getPath())))
            throw new IllegalArgumentException("Invalid verified peer origin");
        return value;
    }
}
