package dev.globalsend.globalsend;

import android.Manifest;
import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.PersistableBundle;
import android.provider.OpenableColumns;
import android.provider.DocumentsContract;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.text.TextUtils;
import android.view.DragAndDropPermissions;
import android.view.DragEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;
import android.widget.FrameLayout;
import androidx.activity.result.PickVisualMediaRequest;
import androidx.activity.result.contract.ActivityResultContracts;
import io.flutter.embedding.android.FlutterView;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.FileInputStream;
import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** User-initiated import/export; no background clipboard reads. */
final class DockCoordinator {
    private final android.content.Context context;
    private java.lang.ref.WeakReference<Activity> attached = new java.lang.ref.WeakReference<>(null);
    private final android.os.Handler main = new android.os.Handler(android.os.Looper.getMainLooper());
    private final MethodChannel channel;
    private final ClipboardSuggestions clipboardSuggestions;
    private final ExecutorService importer = Executors.newSingleThreadExecutor();
    private static WeakReference<DockCoordinator> current = new WeakReference<>(null);
    private static final List<Map<String, Object>> pending = new ArrayList<>();
    private long maxFileSize = 536870912;
    private volatile boolean disposed = false;
    private View dragReceiver;
    private boolean dragActive;
    private int importCount;
    // LocalState stays inside this process, so a return drop can retain the
    // original file/SAF reference instead of importing our own shared URI.
    static final class LocalDrag {
        final String id = UUID.randomUUID().toString();
        final String path, text;
        final List<String> paths,texts;
        final WeakReference<View> source;
        boolean dropped;
        boolean accepted;
        boolean returnedToShelf;
        java.util.function.Consumer<Boolean> completed;
        boolean navigationSelected;
        View.OnAttachStateChangeListener detachListener;
        final List<Runnable> afterEnd = new ArrayList<>();
        LocalDrag(View source, String path, String text) { this(source,path==null?java.util.Collections.emptyList():java.util.Collections.singletonList(path),path==null&&text!=null?java.util.Collections.singletonList(text):java.util.Collections.emptyList()); }
        LocalDrag(View source,List<String> paths,List<String> texts) {this.source=new WeakReference<>(source);this.paths=new ArrayList<>(paths);this.texts=new ArrayList<>(texts);this.path=paths.isEmpty()?null:paths.get(0);this.text=texts.isEmpty()?null:String.join("\n",texts);}
    }
    private static LocalDrag activeExport;
    private String sendServerKey = "";
    private final List<Map<String, String>> sendTargets = new ArrayList<>();
    private static final String LOCAL_DRAG_SESSION = "dev.globalsend.localDrag";
    private RectF queueDropBounds;
    private final Map<String, RectF> deviceDropBounds = new java.util.LinkedHashMap<>();
    private String dropServerKey = "";
    private int queueSurfaceWidth, queueSurfaceHeight;
    private boolean queueDragActive;
    private String hoveredDeviceId = "";
    private LocalDrag hoveredLocal;
    private LocalDrag receivingLocal;
    private RectF sendNavigationBounds;
    private int navigationSurfaceWidth, navigationSurfaceHeight;
    private Runnable navigationHover;
    private float lastDragX, lastDragY;
    static final int PICK_SEND_DIRECTORY = 7837;
    static final int PICK_SEND_MEDIA = 7838;
    private MethodChannel.Result directoryPicker;
    private MethodChannel.Result mediaPicker;
    private final ActivityResultContracts.PickMultipleVisualMedia mediaContract =
        new ActivityResultContracts.PickMultipleVisualMedia(32);

    DockCoordinator(MainActivity activity, FlutterEngine engine) {
        this(activity, new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "dev.globalsend/dock"));
    }

    DockCoordinator(android.content.Context context, MethodChannel channel) {
        this.context = context.getApplicationContext(); current = new WeakReference<>(this);
        if (context instanceof Activity) attach((Activity) context);
        this.channel = channel;
        clipboardSuggestions=new ClipboardSuggestions(this.context,ReceiveOverlay::clipboardChanged);
        channel.setMethodCallHandler((call, result) -> {
            try {
                switch (call.method) {
                    case "clipboardSuggestion":
                        result.success(clipboardSuggestions.refresh(attached.get()!=null && attached.get().hasWindowFocus()));break;
                    case "dismissClipboardSuggestion":
                        clipboardSuggestions.dismiss(call.argument("revision"));result.success(null);break;
                    case "status": result.success(status()); break;
                    case "showShelf": ReceiveOverlay.openShelf(); result.success(null); break;
                    case "hideShelf": ReceiveOverlay.closeShelf(); result.success(null); break;
                    case "installedApps":
                        importer.execute(() -> {
                            try { List<Map<String,Object>> apps = InstalledApps.list(this.context); main.post(() -> result.success(apps)); }
                            catch (Exception error) { main.post(() -> result.error("APP_LIST", "无法读取应用列表", null)); }
                        }); break;
                    case "exportApp":
                        String packageId = call.argument("package");
                        importer.execute(() -> {
                            try { Map<String,Object> app = InstalledApps.export(this.context, packageId); main.post(() -> result.success(app)); }
                            catch (Exception error) { main.post(() -> result.error("APP_EXPORT", "无法导出该应用的安装包", null)); }
                        }); break;
                    case "notificationPermission": if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) host().requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 781); result.success(null); break;
                    case "configure":
                        Number size = call.argument("maxFileSize"); if (size != null) maxFileSize = Math.min(2147483648L, Math.max(0, size.longValue()));
                        result.success(null); break;
                    case "sendTargets":
                        updateSendTargets(call.argument("serverKey"), call.argument("devices"));
                        result.success(null); break;
                    case "queueDropBounds":
                        updateQueueDropBounds(Boolean.TRUE.equals(call.argument("enabled")) ? call.arguments() : null);
                        updateDeviceDropBounds(call.argument("serverKey"), call.argument("devices"));
                        updateSendNavigationBounds(call.argument("sendNavigation"));
                        result.success(null); break;
                    case "pending": synchronized (pending) { result.success(new ArrayList<>(pending)); pending.clear(); } break;
                    case "importClipboard":
                        ClipboardManager clipboard = (ClipboardManager) context.getSystemService(Activity.CLIPBOARD_SERVICE);
                        ClipData data = clipboard.getPrimaryClip();
                        if (data == null || data.getItemCount() == 0) { result.success(null); break; }
                        consume(data, null); result.success(null); break;
                    case "pickDirectory":
                        if (directoryPicker != null) throw new IllegalStateException("文件夹选择器已打开");
                        directoryPicker = result;
                        host().startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION), PICK_SEND_DIRECTORY);
                        break;
                    case "pickMedia":
                        pickMedia(result); break;
                    case "directoryEntries":
                        directoryEntries(Uri.parse(call.argument("location")), result); break;
                    case "startDrag":
                        View view = findFlutterView(host().findViewById(android.R.id.content));
                        String path = call.argument("path"), text = call.argument("text"), label = call.argument("label");
                        if (view == null || !host().hasWindowFocus()) throw new IllegalStateException("Drag from a visible app view");
                        List<String> paths=call.argument("paths"),texts=call.argument("texts");
                        result.success(paths!=null||texts!=null?startDrag(view,paths==null?java.util.Collections.emptyList():paths,texts==null?java.util.Collections.emptyList():texts,label==null?"GlobalSend":label):startDrag(view, path, text, label == null ? "GlobalSend" : label)); break;
                    default: result.notImplemented();
                }
            } catch (Exception e) {
                if (directoryPicker == result) directoryPicker = null;
                if (mediaPicker == result) mediaPicker = null;
                result.error("DOCK_UNAVAILABLE", e.getMessage(), null);
            }
        });
    }

    void attach(Activity activity) { attached = new java.lang.ref.WeakReference<>(activity); }

    void updateSendTargets(String serverKey, List<Map<String, String>> devices) {
        sendServerKey = serverKey == null ? "" : serverKey;
        sendTargets.clear();
        java.util.Set<String> ids = new java.util.HashSet<>();
        if(devices != null) for(Map<String,String> device:devices)
            if(ids.add(device.get("deviceId"))) sendTargets.add(new HashMap<>(device));
        ReceiveOverlay.refreshSendTargets();
    }
    static String sendServerKey() {
        DockCoordinator coordinator=current.get();return coordinator==null?"":coordinator.sendServerKey;
    }
    static List<Map<String,String>> sendTargets() {
        DockCoordinator coordinator=current.get();
        return coordinator==null?java.util.Collections.emptyList():new ArrayList<>(coordinator.sendTargets);
    }
    static boolean sendToDevice(DragEvent event, String serverKey, String deviceId,
            List<String> paths, List<String> texts, java.util.function.Consumer<Boolean> completed) {
        DockCoordinator coordinator=current.get();
        LocalDrag session=coordinator==null?null:coordinator.localSession(event);
        if(coordinator==null || coordinator.disposed || session==null || session!=activeExport || session.dropped ||
            !coordinator.sendServerKey.equals(serverKey) ||
            coordinator.sendTargets.stream().noneMatch(device -> deviceId.equals(device.get("deviceId"))))return false;
        session.dropped=true;session.accepted=true;
        Map<String,Object> selection=new HashMap<>();
        selection.put("serverKey",serverKey);selection.put("deviceId",deviceId);
        selection.put("paths",new ArrayList<>(paths));selection.put("texts",new ArrayList<>(texts));
        coordinator.channel.invokeMethod("sendToDevice",selection,new MethodChannel.Result() {
            public void success(Object value) { completed.accept(true); }
            public void error(String code,String message,Object details) { completed.accept(false); }
            public void notImplemented() { completed.accept(false); }
        });
        return true;
    }
    void detach(Activity activity) {
        if (attached.get() != activity) return;
        detachDragReceiver(); attached.clear();
        // The coordinator and Dart request survive a configuration change with
        // the cached engine. A genuinely removed host must not leave Dart waiting.
        if (!activity.isChangingConfigurations()) finishMediaPicker("MEDIA_PICKER_CLOSED", "媒体选择已结束，请重新选择");
    }
    private Activity host() {
        Activity activity = attached.get();
        if (activity == null || activity.isFinishing()) throw new IllegalStateException("请回到应用操作");
        return activity;
    }

    boolean onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode == PICK_SEND_MEDIA) {
            MethodChannel.Result result = mediaPicker; mediaPicker = null;
            if (result == null) return true; // Closed host or duplicate delivery.
            try {
                List<Uri> uris = mediaContract.parseResult(resultCode, data);
                if (!uris.isEmpty()) {
                    // The document fallback cannot enforce the contract's max.
                    // Reject rather than silently dropping selected videos/files.
                    if (uris.size() > 32) throw new IllegalArgumentException("每次最多选择 32 个媒体文件");
                    for (Uri uri : uris) if (!"content".equals(uri.getScheme())) throw new IllegalArgumentException("媒体来源未提供可读取的内容");
                    ClipData clip = new ClipData("Selected media", new String[]{"image/*", "video/*"}, new ClipData.Item(uris.get(0)));
                    for (int i = 1; i < uris.size(); i++) clip.addItem(new ClipData.Item(uris.get(i)));
                    // Copy bytes immediately using the picker URI's temporary
                    // read grant; no album permission or media transcoding.
                    consume(clip, null);
                }
                result.success(null);
            } catch (Exception error) {
                result.error("MEDIA_IMPORT_FAILED", error.getMessage(), null);
            }
            return true;
        }
        if (requestCode != PICK_SEND_DIRECTORY) return false;
        MethodChannel.Result result = directoryPicker; directoryPicker = null;
        if (result == null) return true;
        if (resultCode != Activity.RESULT_OK || data == null || data.getData() == null) { result.success(null); return true; }
        Uri tree = data.getData();
        try {
            if ((data.getFlags() & Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION) != 0) {
                context.getContentResolver().takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION);
            }
            result.success(SendFolderEntries.selection(context, tree));
        } catch (Exception error) {
            result.error("FOLDER_IMPORT_FAILED", error.getMessage(), null);
        }
        return true;
    }

    private void pickMedia(MethodChannel.Result result) {
        if (mediaPicker != null) throw new IllegalStateException("媒体选择器已打开");
        Activity activity = host();
        Intent intent = mediaContract.createIntent(activity, new PickVisualMediaRequest.Builder()
            .setMediaType(ActivityResultContracts.PickVisualMedia.ImageAndVideo.INSTANCE).build());
        mediaPicker = result;
        activity.startActivityForResult(intent, PICK_SEND_MEDIA);
    }

    private void finishMediaPicker(String code, String message) {
        MethodChannel.Result result = mediaPicker; mediaPicker = null;
        if (result != null) result.error(code, message, null);
    }

    private void directoryEntries(Uri tree, MethodChannel.Result result) {
        importer.execute(() -> {
            try {
                List<Map<String, Object>> entries = SendFolderEntries.read(context, tree);
                main.post(() -> { if (!disposed) result.success(entries); });
            } catch (Exception error) {
                main.post(() -> { if (!disposed) result.error("FOLDER_IMPORT_FAILED", error.getMessage(), null); });
            }
        });
    }
    Map<String, Object> status() {
        Map<String, Object> value = new HashMap<>();
        value.put("notificationPermission", Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED);
        value.put("active", dragActive); value.put("importing", importCount > 0);
        value.put("queueActive", queueDragActive);
        value.put("localSessionActive", activeExport != null || receivingLocal != null);
        return value;
    }
    void attachDragReceiver() {
        View root = host().findViewById(android.R.id.content);
        View flutter = findFlutterView(root);
        if (flutter == null) return; // FlutterActivity calls us again after resume.
        // desktop_drop also owns the content container on Android. Keep native
        // URI import on the actual Flutter surface so no plugin releases its
        // temporary permission before our background copy completes.
        if (root != null) root.setOnDragListener(null);
        if (dragReceiver != null && dragReceiver.getParent() == flutter) return;
        detachDragReceiver();
        // A leaf View receives ENTERED/EXITED. FlutterView is a ViewGroup, whose
        // N+ dispatcher routes those transitions to the innermost drag target.
        // This transparent layer never consumes touch, focus or accessibility.
        dragReceiver = new View(host());
        dragReceiver.setClickable(false); dragReceiver.setFocusable(false);
        dragReceiver.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        dragReceiver.setOnDragListener((view, event) -> acceptDrag(event));
        ((FlutterView) flutter).addView(dragReceiver, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
    }
    private void detachDragReceiver() {
        if (dragReceiver == null) return;
        dragReceiver.setOnDragListener(null);
        if (dragReceiver.getParent() instanceof ViewGroup) ((ViewGroup) dragReceiver.getParent()).removeView(dragReceiver);
        dragReceiver = null;
        // A replaced surface no longer participates in the old drag session,
        // so it may never receive that session's EXITED or ENDED event.
        // Clear hover while retaining any independent import in progress.
        dragActive = false;
        publishDrag("ended");
        hoveredLocal = null;
        receivingLocal = null;
        cancelNavigationHover();
        localHover(false, "ended");
    }
    static View findFlutterView(View root) {
        if (root instanceof FlutterView) return root;
        if (root instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) root;
            for (int i = 0; i < group.getChildCount(); i++) {
                View found = findFlutterView(group.getChildAt(i));
                if (found != null) return found;
            }
        }
        return null;
    }
    private void publishDrag(String phase) {
        if (disposed) return;
        Map<String, Object> state = new HashMap<>();
        state.put("phase", phase); state.put("active", dragActive); state.put("importing", importCount > 0);
        state.put("targetDeviceId", dragActive ? hoveredDeviceId : "");
        channel.invokeMethod("nativeDrag", state);
    }
    void updateQueueDropBounds(Map<String, Object> bounds) {
        if (bounds == null) queueDropBounds = null;
        else {
            queueDropBounds = new RectF(((Number) bounds.get("left")).floatValue(), ((Number) bounds.get("top")).floatValue(),
                ((Number) bounds.get("right")).floatValue(), ((Number) bounds.get("bottom")).floatValue());
            queueSurfaceWidth = ((Number) bounds.get("surfaceWidth")).intValue();
            queueSurfaceHeight = ((Number) bounds.get("surfaceHeight")).intValue();
        }
        if (hoveredLocal != null) localHover(insideQueue(lastDragX, lastDragY), "location");
    }
    private boolean insideQueue(float x, float y) {
        return queueDropBounds != null && (dragReceiver == null ||
            (dragReceiver.getWidth() == queueSurfaceWidth && dragReceiver.getHeight() == queueSurfaceHeight)) && queueDropBounds.contains(x, y);
    }
    void updateDeviceDropBounds(String serverKey, List<Map<String, Object>> devices) {
        deviceDropBounds.clear(); dropServerKey = serverKey == null ? "" : serverKey;
        if(devices != null)for(Map<String,Object> device:devices)deviceDropBounds.put((String)device.get("deviceId"),new RectF(
            ((Number)device.get("left")).floatValue(),((Number)device.get("top")).floatValue(),
            ((Number)device.get("right")).floatValue(),((Number)device.get("bottom")).floatValue()));
        if(hoveredLocal!=null)localHover(insideQueue(lastDragX,lastDragY),"location");
        else if(dragActive) {
            String target=deviceDropAt(lastDragX,lastDragY);
            if(!hoveredDeviceId.equals(target)){hoveredDeviceId=target;publishDrag("location");}
        }
    }
    String deviceDropAt(float x,float y) {
        if(dragReceiver != null && (dragReceiver.getWidth()!=queueSurfaceWidth || dragReceiver.getHeight()!=queueSurfaceHeight))return "";
        for(Map.Entry<String,RectF> entry:deviceDropBounds.entrySet())if(entry.getValue().contains(x,y))return entry.getKey();
        return "";
    }
    void updateSendNavigationBounds(Map<String, Object> bounds) {
        sendNavigationBounds = bounds == null ? null : new RectF(
            ((Number) bounds.get("left")).floatValue(), ((Number) bounds.get("top")).floatValue(),
            ((Number) bounds.get("right")).floatValue(), ((Number) bounds.get("bottom")).floatValue());
        if (bounds != null) {
            navigationSurfaceWidth = ((Number) bounds.get("surfaceWidth")).intValue();
            navigationSurfaceHeight = ((Number) bounds.get("surfaceHeight")).intValue();
        }
        if (sendNavigationBounds == null) cancelNavigationHover();
    }
    private void cancelNavigationHover() {
        if (navigationHover != null) main.removeCallbacks(navigationHover);
        navigationHover = null;
    }
    private void updateNavigationHover(LocalDrag local) {
        if (local.navigationSelected || !insideSendNavigation(lastDragX, lastDragY)) {
            cancelNavigationHover(); return;
        }
        if (navigationHover != null) return;
        navigationHover = () -> {
            navigationHover = null;
            if (disposed || hoveredLocal != local || local.dropped || !insideSendNavigation(lastDragX, lastDragY)) return;
            local.navigationSelected = true;
            Map<String, Object> state = new HashMap<>();
            state.put("local", true); state.put("active", false); state.put("importing", importCount > 0);
            state.put("navigate", "send");
            channel.invokeMethod("nativeDrag", state);
        };
        main.postDelayed(navigationHover, 350);
    }
    private boolean insideSendNavigation(float x, float y) {
        return sendNavigationBounds != null && (dragReceiver == null ||
            (dragReceiver.getWidth() == navigationSurfaceWidth && dragReceiver.getHeight() == navigationSurfaceHeight)) &&
            sendNavigationBounds.contains(x, y);
    }
    private LocalDrag localSession(DragEvent event) {
        if (event.getLocalState() instanceof LocalDrag) return (LocalDrag) event.getLocalState();
        if (event.getAction() != DragEvent.ACTION_DRAG_STARTED && receivingLocal != null) return receivingLocal;
        // localState belongs to the source ViewRoot. A native overlay and the
        // Flutter Activity have different roots, even though they share a process.
        android.content.ClipDescription description = event.getClipDescription();
        PersistableBundle extras = description == null ? null : description.getExtras();
        return activeExport != null && extras != null && activeExport.id.equals(extras.getString(LOCAL_DRAG_SESSION))
            ? activeExport : null;
    }
    private void localHover(boolean active, String phase) {
        String target=phase.equals("location")?deviceDropAt(lastDragX,lastDragY):"";
        active|=!target.isEmpty();
        if (queueDragActive == active && hoveredDeviceId.equals(target) && !phase.equals("ended")) return;
        hoveredDeviceId=target;
        queueDragActive = active;
        Map<String, Object> state = new HashMap<>();
        state.put("phase", phase); state.put("local", true); state.put("active", active); state.put("importing", importCount > 0);
        state.put("sessionActive", activeExport != null || receivingLocal != null);
        state.put("targetDeviceId",target);
        if (!disposed) channel.invokeMethod("nativeDrag", state);
    }
    private void publishLocalSession() {
        Map<String, Object> state = new HashMap<>();
        state.put("local", true); state.put("active", queueDragActive); state.put("importing", importCount > 0);
        state.put("sessionActive", activeExport != null || receivingLocal != null);
        state.put("targetDeviceId",queueDragActive?hoveredDeviceId:"");
        if (!disposed) channel.invokeMethod("nativeDrag", state);
    }
    private boolean acceptLocalDrag(DragEvent event, LocalDrag local) {
        switch (event.getAction()) {
            case DragEvent.ACTION_DRAG_STARTED:
                // Participate even when the send page is not visible yet;
                // queue geometry, not the whole window, decides a real DROP.
                receivingLocal = local;
                publishLocalSession();
                return true;
            case DragEvent.ACTION_DRAG_ENTERED:
            case DragEvent.ACTION_DRAG_LOCATION:
                hoveredLocal = local; lastDragX = event.getX(); lastDragY = event.getY();
                updateNavigationHover(local);
                localHover(insideQueue(lastDragX, lastDragY), "location"); return true;
            case DragEvent.ACTION_DRAG_EXITED:
                hoveredLocal = null; cancelNavigationHover(); localHover(false, "exited"); return true;
            case DragEvent.ACTION_DRAG_ENDED:
                hoveredLocal = null; receivingLocal = null; cancelNavigationHover(); localHover(false, "ended");
                local.accepted |= event.getResult(); finishExport(local); return true;
            case DragEvent.ACTION_DROP:
                hoveredLocal = null; cancelNavigationHover(); localHover(false, "ended");
                String target = deviceDropAt(event.getX(), event.getY());
                if (local.dropped || !insideQueue(event.getX(), event.getY()) && target.isEmpty()) return false;
                local.dropped = true;
                local.accepted = true;
                Map<String, Object> drop = new HashMap<>();
                drop.put("dropId", UUID.randomUUID().toString()); drop.put("local", true);
                drop.put("paths", new ArrayList<>(local.paths));
                drop.put("texts", new ArrayList<>(local.texts));
                drop.put("temporaryPaths", new ArrayList<>());
                if(!target.isEmpty()){drop.put("targetDeviceId",target);drop.put("serverKey",dropServerKey);}
                synchronized (pending) { pending.add(drop); }
                channel.invokeMethod("nativeDrop", drop); return true;
            default: return true;
        }
    }
    boolean acceptDrag(DragEvent event) {
        if (disposed) return false;
        LocalDrag local = localSession(event);
        if (local != null) return acceptLocalDrag(event, local);
        switch (event.getAction()) {
            case DragEvent.ACTION_DRAG_STARTED:
                receivingLocal = null; hoveredLocal = null; cancelNavigationHover();
                if (queueDragActive) localHover(false, "ended");
                return event.getClipDescription() != null;
            case DragEvent.ACTION_DRAG_ENTERED:
            case DragEvent.ACTION_DRAG_LOCATION:
                lastDragX=event.getX();lastDragY=event.getY();
                String hovering=deviceDropAt(lastDragX,lastDragY);
                boolean changed=!dragActive || !hoveredDeviceId.equals(hovering);
                hoveredDeviceId=hovering;dragActive=true;
                if(changed)publishDrag("location");return true;
            case DragEvent.ACTION_DRAG_EXITED:
                dragActive = false; publishDrag("exited"); return true;
            case DragEvent.ACTION_DRAG_ENDED:
                dragActive = false; publishDrag("ended"); return true;
            case DragEvent.ACTION_DROP:
                dragActive = false;
                ClipData clip = event.getClipData();
                if (clip == null || clip.getItemCount() == 0) {
                    publishDrag("ended"); return false;
                }
                // Retain the grant until every source stream is copied. A null
                // grant is valid for plain text and already accessible URIs.
                consume(clip, host().requestDragAndDropPermissions(event), null, deviceDropAt(event.getX(),event.getY()), dropServerKey); return true;
            default:
                return true;
        }
    }
    void handleSharedIntent(Intent intent) {
        if (intent == null || !(Intent.ACTION_SEND.equals(intent.getAction()) || Intent.ACTION_SEND_MULTIPLE.equals(intent.getAction()))) return;
        ClipData clip = intent.getClipData();
        if (clip == null) {
            Uri one = null;
            if (Intent.ACTION_SEND.equals(intent.getAction())) one = Build.VERSION.SDK_INT >= 33 ? intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri.class) : intent.getParcelableExtra(Intent.EXTRA_STREAM);
            if (Intent.ACTION_SEND_MULTIPLE.equals(intent.getAction())) {
                ArrayList<Uri> many = Build.VERSION.SDK_INT >= 33 ? intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri.class) : intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM);
                if (many != null && !many.isEmpty()) { clip = ClipData.newUri(context.getContentResolver(), "Shared files", many.get(0)); for (int i=1;i<many.size();i++) clip.addItem(new ClipData.Item(many.get(i))); }
                one = null;
            }
            if (clip == null && one != null) clip = ClipData.newUri(context.getContentResolver(), "Shared file", one);
            else if (clip == null && intent.getCharSequenceExtra(Intent.EXTRA_TEXT) != null) clip = ClipData.newPlainText("Shared text", intent.getCharSequenceExtra(Intent.EXTRA_TEXT));
        }
        if (clip != null) consume(clip, null);
        intent.setAction(null); // Do not import again on activity resume.
    }
    private final List<DragAndDropPermissions> folderReadGrants = java.util.Collections.synchronizedList(new ArrayList<>());
    private void consume(ClipData clip, DragAndDropPermissions permission) {
        consume(clip, permission, null);
    }

    /** The shelf owns its imports; they must not become received records or queued sends. */
    static Map<String,Object> clipboardSuggestion() {
        DockCoordinator coordinator=current.get();
        return coordinator==null?java.util.Collections.emptyMap():coordinator.clipboardSuggestions.snapshot();
    }
    static void dismissClipboardSuggestion(String revision) {
        DockCoordinator coordinator=current.get();
        if(coordinator!=null)coordinator.clipboardSuggestions.dismiss(revision);
    }
    static void refreshClipboardSuggestion() {
        DockCoordinator coordinator=current.get();
        if(coordinator!=null)coordinator.clipboardSuggestions.refresh(true);
    }
    static boolean importClipboardToShelf(java.util.function.Consumer<Map<String,Object>> completed) {
        DockCoordinator coordinator=current.get();
        if(coordinator==null || coordinator.disposed)return false;
        ClipData clip=coordinator.context.getSystemService(ClipboardManager.class).getPrimaryClip();
        if(clip==null || clip.getItemCount()==0)return false;
        coordinator.clipboardSuggestions.refresh(true);
        coordinator.consume(clip,null,completed);
        return true;
    }
    static boolean importToShelf(DragEvent event, java.util.function.Consumer<Map<String, Object>> completed) {
        DockCoordinator coordinator = current.get();
        if (coordinator == null || coordinator.disposed) return false;
        LocalDrag local = coordinator.localSession(event);
        if (local != null) {
            if (local.dropped) return false;
            local.dropped = true; local.accepted = true;
            local.returnedToShelf = true;
            Map<String, Object> content = new HashMap<>();
            content.put("paths", new ArrayList<>(local.paths));
            content.put("texts", new ArrayList<>(local.texts));
            completed.accept(content);
            return true;
        }
        ClipData clip = event.getClipData();
        if (clip == null || clip.getItemCount() == 0) return false;
        Activity activity = coordinator.attached.get();
        DragAndDropPermissions permission = activity == null ? null : activity.requestDragAndDropPermissions(event);
        coordinator.consume(clip, permission, completed);
        return true;
    }

    private void consume(ClipData clip, DragAndDropPermissions permission,
            java.util.function.Consumer<Map<String, Object>> shelf) {
        consume(clip,permission,shelf,"","");
    }
    private void consume(ClipData clip, DragAndDropPermissions permission,
            java.util.function.Consumer<Map<String, Object>> shelf, String targetDeviceId, String serverKey) {
        importCount++; publishDrag("importing");
        importer.execute(() -> {
            List<String> paths = new ArrayList<>(), texts = new ArrayList<>();
            Map<String, String> directoryNames = new HashMap<>(); String error = null;
            Map<String, String> directorySources = new HashMap<>();
            long sizeLimit = shelf == null ? maxFileSize : Long.MAX_VALUE;
            try {
                File folder = shelf == null ? new File(context.getFilesDir(), "incoming-drops") : new File(context.getCacheDir(), "shelf-imports");
                if (!folder.isDirectory() && !folder.mkdirs()) throw new IllegalStateException("Drop storage unavailable");
                for (int i = 0; i < clip.getItemCount(); i++) {
                    ClipData.Item item = clip.getItemAt(i); Uri uri = item.getUri();
                    if (uri == null) { CharSequence value = item.getText(); if (value != null && value.length() <= 100000) texts.add(value.toString()); continue; }
                    if (!"content".equals(uri.getScheme())) throw new SecurityException("Ask the source app to share a content URI with read permission");
                    if (DocumentsContract.Document.MIME_TYPE_DIR.equals(context.getContentResolver().getType(uri))) {
                        Map<String, String> selection = SendFolderEntries.selection(context, uri);
                        String root = selection.get("source"); paths.add(root); directoryNames.put(root, selection.get("name")); directorySources.put(root, root); continue;
                    }
                    String name = "shared-file";
                    try (Cursor cursor = context.getContentResolver().query(uri, new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE}, null, null, null)) {
                        if (cursor != null && cursor.moveToFirst()) { String display = cursor.getString(0); if (display != null) name = display; if (!cursor.isNull(1) && cursor.getLong(1) > sizeLimit) throw new IllegalStateException("Dropped file exceeds center limit"); }
                    }
                    if(MediaFileName.needsSuffix(name))name=MediaFileName.withType(name,context.getContentResolver().getType(uri));
                    StringBuilder safe = new StringBuilder();
                    for (int j = 0; j < name.length(); j++) { char c = name.charAt(j); safe.append(c < 32 || c == 47 || c == 92 || c == 34 || c == 60 || c == 62 || c == 58 || c == 124 || c == 63 || c == 42 ? '_' : c); }
                    name = safe.toString(); if (name.length() > 160) name = name.substring(name.length() - 160);
                    if (name.equals(".") || name.equals("..")) name = "shared-file";
                    if(name.isEmpty()) name="shared-file";
                    File perFile = new File(folder,UUID.randomUUID().toString()); if(!perFile.mkdirs()) throw new IllegalStateException("Drop storage unavailable");
                    File target = new File(perFile, name), temporary = new File(target.getPath() + ".part");
                    long copied = 0;
                    try {
                        try (InputStream input = context.getContentResolver().openInputStream(uri); FileOutputStream output = new FileOutputStream(temporary)) {
                            if (input == null) throw new IllegalStateException("Source did not grant file access");
                            byte[] bytes = new byte[65536]; int count;
                            while ((count = input.read(bytes)) != -1) {
                                if (disposed || Thread.currentThread().isInterrupted()) throw new InterruptedException();
                                copied += count; if (copied > sizeLimit || folder.getUsableSpace() < 67108864L + count) throw new IllegalStateException("File limit or storage reserve reached");
                                output.write(bytes, 0, count);
                            }
                            output.getFD().sync();
                        }
                        if (!temporary.renameTo(target)) throw new IllegalStateException("Could not commit dropped file"); paths.add(target.getPath());
                    } finally { if (temporary.exists()) temporary.delete(); }
                }
            } catch (Exception e) { error = "Cannot import dropped content: " + e.getClass().getSimpleName(); }
            finally {
                if (permission != null) {
                    if (!directorySources.isEmpty() && !disposed) folderReadGrants.add(permission);
                    else permission.release();
                }
            }
            Map<String, Object> event = new HashMap<>(); event.put("dropId", UUID.randomUUID().toString()); event.put("paths", paths); event.put("temporaryPaths", new ArrayList<>(paths.stream().filter(path -> !path.startsWith("content://")).collect(java.util.stream.Collectors.toList()))); event.put("directoryNames", directoryNames); event.put("directorySources", directorySources); event.put("texts", texts); if (error != null) event.put("error", error);
            if(!targetDeviceId.isEmpty()){event.put("targetDeviceId",targetDeviceId);event.put("serverKey",serverKey);}
            if (shelf == null) synchronized (pending) { pending.add(event); }
            main.post(() -> {
                importCount--;
                if (!disposed) {
                    if (shelf == null) channel.invokeMethod("nativeDrop", event);
                    else shelf.accept(event);
                    publishDrag("imported");
                }
            });
        });
    }
    private static void finishExport(LocalDrag session) {
        if (activeExport != session) return;
        traceDrag("finish export accepted="+session.accepted+" returned="+session.returnedToShelf);
        activeExport = null;
        View source = session.source.get();
        if (source != null) {
            if (!(source instanceof FlutterView)) source.setOnDragListener(null);
            if (session.detachListener != null) source.removeOnAttachStateChangeListener(session.detachListener);
        }
        DockCoordinator coordinator = current.get();
        if (coordinator != null) {
            if (coordinator.receivingLocal == session) coordinator.receivingLocal = null;
            if (coordinator.hoveredLocal == session) coordinator.hoveredLocal = null;
            coordinator.cancelNavigationHover();
            coordinator.queueDragActive = false;
            coordinator.publishLocalSession();
        }
        for (Runnable completed : new ArrayList<>(session.afterEnd)) completed.run();
        session.afterEnd.clear();
        if (session.completed != null) session.completed.accept(session.accepted && !session.returnedToShelf);
    }
    static boolean afterExportFrom(View root, Runnable completed) {
        LocalDrag session = activeExport;
        View view = session == null ? null : session.source.get();
        while (view != null) {
            if (view == root) { session.afterEnd.add(completed); return true; }
            view = view.getParent() instanceof View ? (View) view.getParent() : null;
        }
        return false;
    }
    static void finishExportFrom(View root,DragEvent event) {
        LocalDrag session=activeExport;
        View source=session==null?null:session.source.get();
        while(source!=null) {
            if(source==root) {session.accepted|=event.getResult();finishExport(session);return;}
            source=source.getParent() instanceof View?(View)source.getParent():null;
        }
    }
    static boolean startDrag(View view, String path, String text, String label) throws Exception {
        return startDrag(view,path==null?java.util.Collections.emptyList():java.util.Collections.singletonList(path),path==null&&text!=null?java.util.Collections.singletonList(text):java.util.Collections.emptyList(),label);
    }
    static boolean startDrag(View view,List<String> paths,List<String> texts,String label) throws Exception {
        return startDrag(view, paths, texts, label, null);
    }
    static boolean startDrag(View view,List<String> paths,List<String> texts,String label,
            java.util.function.Consumer<Boolean> completed) throws Exception {
        return startDrag(view,paths,texts,label,completed,false);
    }
    static boolean startDrag(View view,List<String> paths,List<String> texts,String label,
            java.util.function.Consumer<Boolean> completed,boolean rootHandlesDrag) throws Exception {
        if (activeExport != null) return false; // A second long press must not re-enter a live system drag.
        traceDrag("begin export source="+view.getClass().getSimpleName());
        LocalDrag session = new LocalDrag(view, paths,texts);
        session.completed = completed;
        List<ClipData.Item> items=new ArrayList<>();java.util.LinkedHashSet<String> types=new java.util.LinkedHashSet<>();
        int flags = View.DRAG_FLAG_GLOBAL;
        for(String path:paths) {
            Uri uri=DockShareProvider.registerReadSource(view.getContext(),path);
            items.add(new ClipData.Item(uri));String type=view.getContext().getContentResolver().getType(uri);types.add(type==null?"application/octet-stream":type);flags |= View.DRAG_FLAG_GLOBAL_URI_READ;
        }
        for(String text:texts){if(text==null||text.length()>100000)throw new IllegalArgumentException("Invalid drag text");items.add(new ClipData.Item(text));types.add("text/plain");}
        if(items.isEmpty())throw new IllegalArgumentException("没有可拖动的内容");
        ClipData clip=new ClipData(label,types.toArray(new String[0]),items.get(0));for(int i=1;i<items.size();i++)clip.addItem(items.get(i));
        PersistableBundle metadata = new PersistableBundle();
        metadata.putString(LOCAL_DRAG_SESSION, session.id);
        clip.getDescription().setExtras(metadata);
        View shadow = new DragPreview(view, session.path, session.text, label);
        int width = (int) (232 * view.getResources().getDisplayMetrics().density), height = (int) (104 * view.getResources().getDisplayMetrics().density);
        shadow.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY)); shadow.layout(0, 0, width, height);
        session.detachListener = new View.OnAttachStateChangeListener() {
            @Override public void onViewAttachedToWindow(View source) { }
            @Override public void onViewDetachedFromWindow(View source) { finishExport(session); }
        };
        view.addOnAttachStateChangeListener(session.detachListener);
        if (!(view instanceof FlutterView) && !rootHandlesDrag) view.setOnDragListener((source, event) -> {
            traceDrag("source action="+event.getAction()+" result="+event.getResult());
            if (event.getAction() == DragEvent.ACTION_DRAG_ENDED) {
                session.accepted |= event.getResult(); finishExport(session);
            }
            return event.getAction() == DragEvent.ACTION_DRAG_STARTED || event.getAction() == DragEvent.ACTION_DRAG_ENDED;
        });
        activeExport = session;
        try {
            if (!view.startDragAndDrop(clip, new View.DragShadowBuilder(shadow), session, flags)) {
                finishExport(session);
                throw new IllegalStateException("系统未能开始拖放，请松手后重试");
            }
            DockCoordinator coordinator = current.get();
            if (activeExport == session && coordinator != null) coordinator.publishLocalSession();
            traceDrag("native start returned active="+(activeExport==session));
            return true;
        } catch (Exception error) { finishExport(session); throw error; }
    }

    static void traceDrag(String event) {
        if(android.util.Log.isLoggable("GlobalSendDrag",android.util.Log.DEBUG))android.util.Log.d("GlobalSendDrag",event);
    }

    static final class DragPreview extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
        private final float dp;
        private final String label, text;
        private final ReceiveAppearance appearance;
        private Bitmap bitmap;
        DragPreview(View source, String path, String text, String label) {
            super(source.getContext()); dp = getResources().getDisplayMetrics().density;
            appearance = ReceiveAppearance.load(source.getContext());
            this.label = label; this.text = text;
            if (path != null) {
                try {
                    BitmapFactory.Options options = new BitmapFactory.Options(); options.inJustDecodeBounds = true;
                    try (InputStream input = stream(path)) { BitmapFactory.decodeStream(input, null, options); }
                    options.inSampleSize = 1;
                    while (Math.max(options.outWidth, options.outHeight) / options.inSampleSize > 300) options.inSampleSize *= 2;
                    options.inJustDecodeBounds = false;
                    try (InputStream input = stream(path)) { bitmap = BitmapFactory.decodeStream(input, null, options); }
                } catch (Exception ignored) { /* Generic document artwork is the normal non-image preview. */ }
            }
        }
        private InputStream stream(String path) throws Exception {
            return AndroidReadSource.openStream(getContext(), path);
        }
        @Override protected void onDraw(Canvas canvas) {
            canvas.scale(dp, dp);
            RectF card = new RectF(2, 2, 230, 100);
            paint.setStyle(Paint.Style.FILL); paint.setColor(appearance.surface); canvas.drawRoundRect(card, 18, 18, paint);
            paint.setStyle(Paint.Style.STROKE); paint.setStrokeWidth(1); paint.setColor(appearance.border); canvas.drawRoundRect(card, 18, 18, paint); paint.setStyle(Paint.Style.FILL);
            RectF artwork = new RectF(14, 16, 82, 84);
            paint.setColor(appearance.soft); canvas.drawRoundRect(artwork, 11, 11, paint);
            if (bitmap != null) {
                int checkpoint = canvas.save(); Path clip = new Path(); clip.addRoundRect(artwork, 11, 11, Path.Direction.CW); canvas.clipPath(clip);
                float scale = Math.max(artwork.width() / bitmap.getWidth(), artwork.height() / bitmap.getHeight());
                float width = bitmap.getWidth() * scale, height = bitmap.getHeight() * scale;
                canvas.drawBitmap(bitmap, null, new RectF(artwork.centerX() - width / 2, artwork.centerY() - height / 2, artwork.centerX() + width / 2, artwork.centerY() + height / 2), paint); canvas.restoreToCount(checkpoint);
            } else {
                paint.setColor(appearance.accent); paint.setStrokeWidth(2); paint.setStyle(Paint.Style.STROKE); canvas.drawRoundRect(new RectF(35, 31, 61, 69), 4, 4, paint);
                canvas.drawLine(41, 42, 55, 42, paint); canvas.drawLine(41, 49, 55, 49, paint); canvas.drawLine(41, 56, 51, 56, paint); paint.setStyle(Paint.Style.FILL);
            }
            paint.setTextSize(14); paint.setColor(appearance.ink); paint.setTypeface(android.graphics.Typeface.create("sans-serif-medium", 0));
            canvas.drawText(TextUtils.ellipsize(label.replace('\n', ' '), new android.text.TextPaint(paint), 125, TextUtils.TruncateAt.END).toString(), 94, 42, paint);
            paint.setTextSize(12); paint.setColor(appearance.muted); paint.setTypeface(android.graphics.Typeface.DEFAULT);
            String subtitle = text == null ? (bitmap == null ? "文件" : "图片") : text.replace('\n', ' ');
            canvas.drawText(TextUtils.ellipsize(subtitle, new android.text.TextPaint(paint), 125, TextUtils.TruncateAt.END).toString(), 94, 66, paint);
        }
    }
    void resumed() { attachDragReceiver(); channel.invokeMethod("dockState", status()); }
    void dispose() {
        disposed = true;
        clipboardSuggestions.dispose();
        synchronized (folderReadGrants) {
            for (DragAndDropPermissions grant : folderReadGrants) grant.release();
            folderReadGrants.clear();
        }
        finishMediaPicker("MEDIA_PICKER_CLOSED", "媒体选择已结束，请重新选择");
        detachDragReceiver(); importer.shutdownNow();
        if (current.get() == this) {
            LocalDrag session = activeExport;
            if (session != null) {
                View source = session.source.get();
                if (source != null) source.cancelDragAndDrop();
                finishExport(session);
            }
            current.clear();
        }
        channel.setMethodCallHandler(null);
    }
}
