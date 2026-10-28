package dev.globalsend.globalsend;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.os.Build;
import android.os.Environment;
import android.provider.DocumentsContract;
import android.provider.OpenableColumns;
import android.provider.Settings;
import android.system.Os;
import android.system.OsConstants;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import java.io.FileDescriptor;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.RandomAccessFile;
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
                case "allFilesAccess": result.success(allFilesAccess()); break;
                case "allFilesSettings":
                    try { openAllFilesSettings(); result.success(null); }
                    catch (Exception error) { fail(result, error); }
                    break;
                case "downloads": submit(result, this::downloads); break;
                case "create": submit(result, () -> create(call.argument("destinationLocation"), call.argument("name"))); break;
                case "directory": submit(result, () -> directory(call.argument("parentLocation"), call.argument("name"), Boolean.TRUE.equals(call.argument("unique")))); break;
                case "open": submit(result, () -> open(call.argument("location"), Boolean.TRUE.equals(call.argument("writable")))); break;
                case "openLocalRead": submit(result, () -> openLocalRead(call.argument("path"))); break;
                case "localExists": submit(result, () -> localExists(call.argument("path"))); break;
                case "localStat": submit(result, () -> localStat(call.argument("path"))); break;
                case "readDescriptor": submit(result, () -> readDescriptor(call.argument("handle"), ((Number)call.argument("offset")).longValue(), ((Number)call.argument("length")).intValue())); break;
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
                .putExtra(Intent.EXTRA_LOCAL_ONLY, true)
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
                String label;
                try (Cursor cursor = context.getContentResolver().query(folder,
                    new String[]{DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_FLAGS}, null, null, null)) {
                    if (cursor == null || !cursor.moveToFirst()) throw new FileNotFoundException("文件夹已不存在");
                    if ((cursor.getInt(1) & DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE) == 0) throw new IOException("该文件夹不允许创建文件");
                    label = cursor.getString(0);
                }
                File direct = physicalDocument(tree);
                if (direct != null) {
                    validateLocalDirectory(direct);
                    return localSelection(direct);
                }
                validateWritable(tree.toString());
                Map<String, Object> selection = new HashMap<>();
                selection.put("location", tree.toString()); selection.put("label", label); return selection;
            });
        } catch (Exception error) { fail(result, error); }
        return true;
    }

    boolean allFilesAccess() {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && Environment.isExternalStorageManager();
    }

    void openAllFilesSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R)
            throw new IllegalStateException("此系统请使用文件夹选择器");
        try {
            host().startActivity(new Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:" + context.getPackageName())));
        } catch (android.content.ActivityNotFoundException unavailable) {
            host().startActivity(new Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION));
        }
    }

    Map<String, Object> downloads() throws Exception {
        if (!allFilesAccess()) throw new IOException("请先在系统设置中允许管理所有文件，再选择 Download/GlobalSend");
        File folder = new File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "GlobalSend");
        if (!folder.isDirectory() && !folder.mkdirs()) throw new IOException("无法创建 Download/GlobalSend");
        validateLocalDirectory(folder);
        return localSelection(folder.getCanonicalFile());
    }

    private static Map<String, Object> localSelection(File folder) throws IOException {
        Map<String, Object> value = new HashMap<>();
        value.put("location", folder.getCanonicalPath()); value.put("label", folder.getCanonicalPath());
        return value;
    }

    /** A real local path is used only after the user grants Android's all-files access. */
    File physicalDocument(Uri document) throws IOException {
        if (!allFilesAccess() || !"com.android.externalstorage.documents".equals(document.getAuthority())) return null;
        String id;
        try { id = DocumentsContract.getDocumentId(document); }
        catch (IllegalArgumentException treeOnly) { id = DocumentsContract.getTreeDocumentId(document); }
        int split = id.indexOf(':');
        if (split < 0 || !"primary".equalsIgnoreCase(id.substring(0, split))) return null;
        File root = Environment.getExternalStorageDirectory().getCanonicalFile();
        File selected = new File(root, id.substring(split + 1)).getCanonicalFile();
        if (!selected.equals(root) && !selected.getPath().startsWith(root.getPath() + File.separator))
            throw new IOException("文件夹不在所选存储设备内");
        return selected;
    }

    /** Recover a previously selected physical path through its still-held SAF grant. */
    Uri grantedDocument(String path) throws IOException {
        return grantedDocument(context, path);
    }
    static Uri grantedDocument(Context context, String path) throws IOException {
        File root = Environment.getExternalStorageDirectory().getCanonicalFile();
        File selected = new File(path).getCanonicalFile();
        if (!selected.getPath().startsWith(root.getPath() + File.separator)) return null;
        String relative = selected.getPath().substring(root.getPath().length() + 1).replace(File.separatorChar, '/');
        String id = "primary:" + relative;
        for (android.content.UriPermission grant : context.getContentResolver().getPersistedUriPermissions()) {
            Uri tree = grant.getUri();
            if (!grant.isReadPermission() || !"com.android.externalstorage.documents".equals(tree.getAuthority()) || !DocumentsContract.isTreeUri(tree)) continue;
            String parent = DocumentsContract.getTreeDocumentId(tree);
            if (id.equals(parent) || id.startsWith(parent.endsWith(":") ? parent : parent + "/"))
                return DocumentsContract.buildDocumentUriUsingTree(tree, id);
        }
        return null;
    }

    /** Read/share through the user's existing document grant when a raw path is denied. */
    static String readableLocation(Context context, String location) throws IOException {
        if (location.startsWith("content://") || new File(location).isDirectory()) return location;
        try (RandomAccessFile file = new RandomAccessFile(location, "r")) { return location; }
        catch (FileNotFoundException unavailable) {
            Uri granted = grantedDocument(context, location);
            if (granted != null) return granted.toString();
            throw unavailable;
        }
    }

    boolean localExists(String path) throws Exception {
        return Boolean.TRUE.equals(localStat(path).get("exists"));
    }

    Map<String, Object> localStat(String path) throws Exception {
        Map<String, Object> value = new HashMap<>();
        value.put("location", path); value.put("name", new File(path).getName());
        value.put("size", 0L); value.put("exists", false);
        try {
            android.system.StructStat info = Os.stat(path);
            value.put("exists", true); value.put("size", OsConstants.S_ISREG(info.st_mode) ? info.st_size : 0L);
            return value;
        }
        catch (android.system.ErrnoException error) {
            // Scoped storage can hide a raw path as ENOENT even while its
            // already-authorized document URI is readable.
            Uri granted = grantedDocument(path);
            if (granted != null) {
                value.putAll(stat(granted.toString())); value.put("location", path); return value;
            }
            if (error.errno == OsConstants.ENOENT || error.errno == OsConstants.ENOTDIR) return value;
            throw new IOException("无法读取这个文件；请重新授权所在文件夹", error);
        }
    }

    Map<String, Object> openLocalRead(String path) throws Exception {
        try (RandomAccessFile file = new RandomAccessFile(path, "r")) {
            Map<String, Object> value = new HashMap<>();
            value.put("location", path); value.put("ioPath", path); value.put("handle", "");
            value.put("name", new File(path).getName()); value.put("size", file.length());
            return value;
        } catch (FileNotFoundException error) {
            Uri granted = grantedDocument(path);
            if (granted != null) return open(granted.toString(), false);
            if (!localExists(path)) throw new FileNotFoundException("文件已不存在");
            throw new IOException("无法读取这个文件；请重新授权所在文件夹", error);
        }
    }

    byte[] readDescriptor(String token, long offset, int length) throws Exception {
        if (offset < 0 || length < 0 || length > 1048576) throw new IllegalArgumentException("Invalid read bounds");
        ParcelFileDescriptor descriptor = leases.get(token);
        if (descriptor == null) throw new IOException("文件读取已结束，请重新打开");
        byte[] bytes = new byte[length];
        int count = Os.pread(descriptor.getFileDescriptor(), bytes, 0, length, offset);
        return count <= 0 ? new byte[0] : count == length ? bytes : java.util.Arrays.copyOf(bytes, count);
    }

    static void validateLocalDirectory(File folder) throws Exception {
        if (!folder.isDirectory()) throw new IOException("接收文件夹已不存在，请重新选择");
        File probe = File.createTempFile(".globalsend-write-test-", ".tmp", folder);
        try (RandomAccessFile file = new RandomAccessFile(probe, "rw")) {
            file.write(new byte[]{71, 83}); file.seek(1); file.write(82); file.seek(0);
            if (file.read() != 71 || file.read() != 82) throw new IOException("接收文件夹无法读写");
            file.getFD().sync();
        } finally {
            if (!probe.delete() && probe.exists()) throw new IOException("接收文件夹无法清理临时文件");
        }
    }

    /** Validate the exact receive path before this selection becomes active. */
    void validateWritable(String location) throws Exception {
        Map<String, Object> probe = create(location, ".globalsend-write-test-" + UUID.randomUUID() + ".tmp");
        try {
            try (RandomAccessFile file = new RandomAccessFile((String) probe.get("ioPath"), "rw")) {
                file.write(new byte[]{71, 83}); file.seek(1); file.write(82);
                file.seek(0);
                if (file.read() != 71 || file.read() != 82) throw new IOException("此文件夹无法直接读写，请选择本机文件夹或使用默认目录");
                file.getFD().sync();
            }
        } finally {
            try { close((String) probe.get("handle"), null); }
            finally { delete((String) probe.get("location")); }
        }
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
            boolean descriptorOnly = false;
            try { path = descriptorAccess.checkedPath(descriptor, writable); }
            catch (Exception unsupported) {
                android.util.Log.w("GlobalSendDestination", "Direct access failed: provider=" + document.getAuthority() +
                    ", writable=" + writable + ", cause=" + unsupported.getClass().getSimpleName() +
                    (unsupported instanceof android.system.ErrnoException ? ", errno=" + ((android.system.ErrnoException) unsupported).errno : ""));
                File direct = physicalDocument(document);
                if (!writable) {
                    // The granted descriptor itself can be read even when FUSE
                    // forbids reopening its /proc path. Keep it; do not copy.
                    if (descriptor.getStatSize() < 0) throw new IOException("提供文件的应用不支持随机读取，请选择设备本地文件");
                    path = "";
                    descriptorOnly = true;
                } else {
                    if (direct == null) throw new IOException("此文件夹无法直接读写；可使用默认目录，或开启所有文件访问后重试", unsupported);
                    if (!direct.isFile()) throw new FileNotFoundException("接收文件已不存在，请重新选择目录");
                    try (RandomAccessFile probe = new RandomAccessFile(direct, writable ? "rw" : "r")) {
                        probe.seek(probe.getFilePointer());
                    }
                    path = direct.getPath();
                }
            }
            Map<String, Object> value = stat(location);
            if (!Boolean.TRUE.equals(value.get("exists"))) throw new FileNotFoundException("文件已不存在");
            value.remove("exists"); value.put("ioPath", path); value.put("handle", token);
            value.put("descriptorOnly", descriptorOnly);
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
