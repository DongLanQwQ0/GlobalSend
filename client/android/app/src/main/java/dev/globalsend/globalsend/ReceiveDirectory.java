package dev.globalsend.globalsend;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.provider.OpenableColumns;
import android.system.Os;
import android.system.OsConstants;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import java.io.FileDescriptor;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** SAF destinations: canonical document identities plus short-lived same-process I/O leases. */
final class ReceiveDirectory {
    static final int PICK_DIRECTORY = 7836;
    private static final String PREFS = "globalsend-receive-destination", OWNED = "created-document-uris";
    private static final Object REGISTRY_LOCK = new Object();
    private final Context context;
    private java.lang.ref.WeakReference<Activity> attached = new java.lang.ref.WeakReference<>(null);
    private final android.os.Handler main = new android.os.Handler(android.os.Looper.getMainLooper());
    private final MethodChannel channel;
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Map<String, ParcelFileDescriptor> leases = new ConcurrentHashMap<>();
    private final Set<MethodChannel.Result> requests = ConcurrentHashMap.newKeySet();
    private final DescriptorAccess descriptorAccess;
    private MethodChannel.Result picker;
    private volatile boolean disposed;

    interface DescriptorAccess { String checkedPath(ParcelFileDescriptor descriptor, boolean writable) throws Exception; }
    private static final DescriptorAccess PROC_DESCRIPTOR = (descriptor, writable) -> {
        String path = "/proc/self/fd/" + descriptor.getFd();
        // rw documents must be seekable. Also prove that this exact descriptor
        // can be reopened by Dart/Java File I/O in the application's process.
        Os.lseek(descriptor.getFileDescriptor(), 0, OsConstants.SEEK_CUR);
        FileDescriptor probe = Os.open(path, (writable ? OsConstants.O_RDWR : OsConstants.O_RDONLY) | OsConstants.O_CLOEXEC, 0);
        Os.close(probe);
        return path;
    };

    ReceiveDirectory(Context context, FlutterEngine engine) {
        this(context, new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "dev.globalsend/receive_destination"), PROC_DESCRIPTOR);
    }
    ReceiveDirectory(Context context, MethodChannel channel, DescriptorAccess descriptorAccess) {
        this.context = context.getApplicationContext(); this.channel = channel; this.descriptorAccess = descriptorAccess;
        if (context instanceof Activity) attach((Activity) context);
        channel.setMethodCallHandler((call, result) -> {
            if (disposed) { result.error("DESTINATION_CLOSED", "目录连接已关闭，请重试", null); return; }
            switch (call.method) {
                case "pick": pick(result); break;
                case "create": submit(result, () -> create(call.argument("destinationLocation"), call.argument("name"))); break;
                case "directory": submit(result, () -> directory(call.argument("parentLocation"), call.argument("name"), Boolean.TRUE.equals(call.argument("unique")))); break;
                case "open": submit(result, () -> open(call.argument("location"), Boolean.TRUE.equals(call.argument("writable")))); break;
                case "close": submit(result, () -> { close(call.argument("handle"), call.argument("error")); return null; }); break;
                case "isOwned": result.success(isOwned(context, call.argument("location"))); break;
                case "stat": submit(result, () -> stat(call.argument("location"))); break;
                case "rename": submit(result, () -> rename(call.argument("location"), call.argument("name"))); break;
                case "delete": submit(result, () -> delete(call.argument("location"))); break;
                case "openExternal":
                    try {
                        Uri document = contentUri(call.argument("location"));
                        String type = context.getContentResolver().getType(document);
                        host().startActivity(new Intent(Intent.ACTION_VIEW).setDataAndType(document, type == null ? "application/octet-stream" : type)
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION));
                        result.success(null);
                    } catch (Exception error) { fail(result, error); }
                    break;
                default: result.notImplemented();
            }
        });
    }

    void attach(Activity activity) { attached = new java.lang.ref.WeakReference<>(activity); }
    void detach(Activity activity) { if (attached.get() == activity) attached.clear(); }
    private Activity host() {
        Activity activity = attached.get();
        if (activity == null || activity.isFinishing()) throw new IllegalStateException("请回到应用选择文件夹");
        return activity;
    }

    void pick(MethodChannel.Result result) {
        if (picker != null) { result.error("DIRECTORY_PICK_PENDING", "文件夹选择器已打开", null); return; }
        picker = result;
        try {
            host().startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION |
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION), PICK_DIRECTORY);
        } catch (Exception error) { picker = null; fail(result, error); }
    }

    boolean onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != PICK_DIRECTORY) return false;
        MethodChannel.Result result = picker; picker = null;
        if (result == null) return true;
        if (resultCode != Activity.RESULT_OK) { result.success(null); return true; }
        try {
            Uri tree = data == null ? null : data.getData();
            if (tree == null || !DocumentsContract.isTreeUri(tree) || !"content".equals(tree.getScheme())) {
                throw new IOException("请选择一个文件夹");
            }
            int granted = data.getFlags() & (Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
            if ((granted & Intent.FLAG_GRANT_WRITE_URI_PERMISSION) == 0 || (granted & Intent.FLAG_GRANT_READ_URI_PERMISSION) == 0) {
                throw new SecurityException("请选择允许读写的文件夹");
            }
            context.getContentResolver().takePersistableUriPermission(tree, granted);
            submit(result, () -> {
                Uri folder = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree));
                try (Cursor cursor = context.getContentResolver().query(folder,
                    new String[]{DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_FLAGS}, null, null, null)) {
                    if (cursor == null || !cursor.moveToFirst()) throw new FileNotFoundException("文件夹已不存在");
                    if ((cursor.getInt(1) & DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE) == 0) throw new IOException("该文件夹不允许创建文件");
                    Map<String, Object> selection = new HashMap<>();
                    selection.put("location", tree.toString()); selection.put("label", cursor.getString(0)); return selection;
                }
            });
        } catch (Exception error) { fail(result, error); }
        return true;
    }

    Map<String, Object> create(String destinationLocation, String name) throws Exception {
        checkName(name);
        Uri tree = contentUri(destinationLocation);
        if (!DocumentsContract.isTreeUri(tree)) throw new IOException("请重新选择接收文件夹");
        String parentId = directoryId(tree);
        Uri parent = DocumentsContract.buildDocumentUriUsingTree(tree, parentId);
        Children existing = children(tree, null);
        String chosen = uniqueName(name, existing.names);
        Uri created = DocumentsContract.createDocument(context.getContentResolver(), parent, DockShareProvider.mimeType(chosen), chosen);
        if (created == null) throw new IOException("目录服务未创建文件");
        if (existing.ids.contains(DocumentsContract.getDocumentId(created))) throw new IOException("目录服务未分配新文件，请更换保存文件夹");
        register(context, created.toString(), null);
        rememberParent(created.toString(), parent.toString());
        try {
            Map<String, Object> opened = open(created.toString(), true);
            if (disposed) { close((String) opened.get("handle"), "Activity closed"); throw new IOException("目录连接已关闭，请重试"); }
            return opened;
        }
        catch (Exception error) {
            if (DocumentsContract.deleteDocument(context.getContentResolver(), created)) register(context, null, created.toString());
            throw error;
        }
    }

    String directory(String parentLocation, String name, boolean unique) throws Exception {
        checkName(name);
        Uri tree = contentUri(parentLocation);
        String parentId = directoryId(tree);
        Uri parent = DocumentsContract.buildDocumentUriUsingTree(tree, parentId);
        Children existing = children(parent, null);
        if (!unique) {
            Uri query = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId);
            try (Cursor cursor = context.getContentResolver().query(query, new String[]{DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE}, null, null, null)) {
                if (cursor == null) throw new IOException("无法读取保存文件夹");
                while (cursor.moveToNext()) if (name.equals(cursor.getString(1))) {
                    if (!DocumentsContract.Document.MIME_TYPE_DIR.equals(cursor.getString(2))) throw new IOException("目录路径已被文件占用");
                    return DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0)).toString();
                }
            }
        }
        String chosen = unique ? uniqueName(name, existing.names) : name;
        Uri created = DocumentsContract.createDocument(context.getContentResolver(), parent, DocumentsContract.Document.MIME_TYPE_DIR, chosen);
        if (created == null || existing.ids.contains(DocumentsContract.getDocumentId(created))) throw new IOException("目录服务未创建新文件夹");
        register(context, created.toString(), null); rememberParent(created.toString(), parent.toString());
        return created.toString();
    }

    private String directoryId(Uri location) {
        // A tree-scoped document points at its own folder, not the grant root.
        try { return DocumentsContract.getDocumentId(location); }
        catch (IllegalArgumentException treeOnly) { return DocumentsContract.getTreeDocumentId(location); }
    }
    private void rememberParent(String location, String parent) throws IOException {
        if (!context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("parent:" + location, parent).commit()) throw new IOException("无法保存文件父目录");
    }
    private Uri parentOf(Uri document) {
        String value = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("parent:" + document, null);
        return value == null ? DocumentsContract.buildDocumentUriUsingTree(document, DocumentsContract.getTreeDocumentId(document)) : Uri.parse(value);
    }

    Map<String, Object> open(String location, boolean writable) throws Exception {
        if (writable) requireOwned(location);
        Uri document = contentUri(location);
        ParcelFileDescriptor descriptor = context.getContentResolver().openFileDescriptor(document, writable ? "rw" : "r");
        if (descriptor == null) throw new IOException("目录服务暂不可用，请重试");
        String token = UUID.randomUUID().toString();
        try {
            String path;
            try { path = descriptorAccess.checkedPath(descriptor, writable); }
            catch (Exception unsupported) { throw new IOException("该目录不支持直接读写，请选择设备本地文件夹", unsupported); }
            Map<String, Object> value = stat(location);
            if (!Boolean.TRUE.equals(value.get("exists"))) throw new FileNotFoundException("文件已不存在");
            value.remove("exists"); value.put("ioPath", path); value.put("handle", token);
            long size = descriptor.getStatSize(); if (size >= 0) value.put("size", size);
            synchronized (leases) {
                if (disposed) throw new IOException("目录连接已关闭，请重试");
                leases.put(token, descriptor);
            }
            return value;
        } catch (Exception error) { descriptor.close(); throw error; }
    }

    void close(String token, String error) throws IOException {
        ParcelFileDescriptor descriptor = leases.remove(token);
        if (descriptor == null) return;
        if (error != null && descriptor.canDetectErrors()) descriptor.closeWithError(error); else descriptor.close();
    }

    Map<String, Object> stat(String location) throws Exception {
        Uri document = contentUri(location);
        Map<String, Object> value = new HashMap<>();
        value.put("location", location); value.put("name", ""); value.put("size", 0L); value.put("exists", false);
        try (Cursor cursor = context.getContentResolver().query(document,
            new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                value.put("exists", true); value.put("name", cursor.getString(0));
                value.put("size", cursor.isNull(1) ? -1L : cursor.getLong(1));
            }
        } catch (RuntimeException error) {
            if (!(error.getCause() instanceof FileNotFoundException)) throw error;
        }
        return value;
    }

    Map<String, Object> rename(String location, String name) throws Exception {
        requireOwned(location); checkName(name);
        Uri document = contentUri(location);
        Map<String, Object> before = stat(location);
        if (name.equals(before.get("name"))) return before;
        Uri parent = parentOf(document);
        String next = uniqueName(name, children(parent, DocumentsContract.getDocumentId(document)).names);
        Uri renamed = DocumentsContract.renameDocument(context.getContentResolver(), document, next);
        if (renamed == null) throw new IOException("目录服务未完成改名");
        register(context, renamed.toString(), location);
        rememberParent(renamed.toString(), parent.toString());
        return stat(renamed.toString());
    }

    boolean delete(String location) throws Exception {
        requireOwned(location);
        if (!Boolean.TRUE.equals(stat(location).get("exists"))) { register(context, null, location); return false; }
        Uri document = contentUri(location);
        if (DocumentsContract.Document.MIME_TYPE_DIR.equals(context.getContentResolver().getType(document)) && !children(document, null).ids.isEmpty()) return false;
        if (!DocumentsContract.deleteDocument(context.getContentResolver(), document)) throw new IOException("目录服务未删除文件");
        register(context, null, location); return true;
    }

    static boolean isOwned(Context context, String location) {
        synchronized (REGISTRY_LOCK) {
            return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getStringSet(OWNED, new HashSet<>()).contains(location);
        }
    }
    private void requireOwned(String location) throws IOException {
        if (!isOwned(context, location)) throw new IOException("只能修改本应用创建并登记的接收文件");
    }
    private static void register(Context context, String add, String remove) throws IOException {
        synchronized (REGISTRY_LOCK) {
            android.content.SharedPreferences preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
            Set<String> owned = new HashSet<>(preferences.getStringSet(OWNED, new HashSet<>()));
            if (remove != null) owned.remove(remove);
            if (add != null) owned.add(add);
            if (!preferences.edit().putStringSet(OWNED, owned).commit()) throw new IOException("无法保存接收文件登记");
        }
    }
    private static Uri contentUri(String location) throws IOException {
        Uri uri = location == null ? null : Uri.parse(location);
        if (uri == null || !"content".equals(uri.getScheme()) || uri.getAuthority() == null) throw new IOException("无效的保存目录或文件 URI");
        return uri;
    }
    private static void checkName(String name) throws IOException {
        if (name == null || name.isEmpty() || name.equals(".") || name.equals("..") || name.contains("/") || name.contains("\\")) throw new IOException("文件名无效");
    }
    private static final class Children { final Set<String> names = new HashSet<>(), ids = new HashSet<>(); }
    private Children children(Uri tree, String excludedId) throws Exception {
        Children result = new Children();
        Uri children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, directoryId(tree));
        try (Cursor cursor = context.getContentResolver().query(children,
            new String[]{DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME}, null, null, null)) {
            if (cursor == null) throw new IOException("无法读取保存文件夹");
            while (cursor.moveToNext()) {
                String id = cursor.getString(0);
                result.ids.add(id);
                if (!id.equals(excludedId)) result.names.add(cursor.getString(1).toLowerCase(Locale.ROOT));
            }
        }
        return result;
    }
    static String uniqueName(String name, Set<String> existingLowercase) {
        int dot = name.lastIndexOf('.');
        String stem = dot > 0 ? name.substring(0, dot) : name, extension = dot > 0 ? name.substring(dot) : "";
        String candidate = name; int index = 0;
        while (existingLowercase.contains(candidate.toLowerCase(Locale.ROOT))) candidate = stem + " (" + (++index) + ")" + extension;
        return candidate;
    }
    private interface Work { Object run() throws Exception; }
    private void submit(MethodChannel.Result result, Work work) {
        requests.add(result);
        io.execute(() -> {
            try {
                Object value = work.run();
                main.post(() -> { if (requests.remove(result)) result.success(value); });
            } catch (Exception error) {
                main.post(() -> { if (requests.remove(result)) fail(result, error); });
            }
        });
    }
    private static void fail(MethodChannel.Result result, Exception error) {
        result.error("RECEIVE_DIRECTORY", error.getMessage() == null ? error.getClass().getSimpleName() : error.getMessage(), null);
    }
    void dispose() {
        disposed = true;
        if (picker != null) { picker.error("DIRECTORY_PICKER_CLOSED", "文件夹选择已关闭，请重试", null); picker = null; }
        for (MethodChannel.Result result : new ArrayList<>(requests)) if (requests.remove(result)) result.error("DESTINATION_CLOSED", "目录连接已关闭，请重试", null);
        io.shutdownNow();
        synchronized (leases) {
            for (String token : new ArrayList<>(leases.keySet())) { try { close(token, "Activity closed"); } catch (IOException ignored) {} }
        }
        channel.setMethodCallHandler(null);
    }
}
