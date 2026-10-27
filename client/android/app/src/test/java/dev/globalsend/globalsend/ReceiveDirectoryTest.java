package dev.globalsend.globalsend;

import static org.junit.Assert.*;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.ProviderInfo;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.CancellationSignal;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.os.Environment;
import android.provider.DocumentsContract;
import android.provider.DocumentsProvider;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.Implements;
import org.robolectric.annotation.Implementation;
import org.robolectric.annotation.RealObject;
import org.robolectric.shadows.ShadowContentResolver;
import org.robolectric.shadows.ShadowEnvironment;

/** Uses synthetic DocumentsProvider data, never a user's document directory. */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28, manifest = Config.NONE, shadows = {ReceiveDirectoryTest.ModernDocumentQueries.class, ReceiveDirectoryTest.GrantedEnvironment.class})
public class ReceiveDirectoryTest {
    private Activity activity;
    private ReceiveDirectory directory;
    private FixtureDocuments provider;
    private final Uri tree = DocumentsContract.buildTreeDocumentUri("receive-fixtures", "selected");
    private final BinaryMessenger messenger = new BinaryMessenger() {
        @Override public void send(String channel, ByteBuffer message) {}
        @Override public void send(String channel, ByteBuffer message, BinaryReply callback) {}
        @Override public void setMessageHandler(String channel, BinaryMessageHandler handler) {}
    };

    @Before public void setup() throws Exception {
        GrantedEnvironment.allowed = false;
        activity = Robolectric.buildActivity(Activity.class).setup().get();
        provider = new FixtureDocuments();
        provider.folder = new File(activity.getCacheDir(), "selected-saf-fixture"); provider.folder.mkdirs();
        ProviderInfo info = new ProviderInfo(); info.authority = "receive-fixtures";
        info.exported = true; info.grantUriPermissions = true;
        info.readPermission = Manifest.permission.MANAGE_DOCUMENTS;
        info.writePermission = Manifest.permission.MANAGE_DOCUMENTS;
        provider.attachInfo(activity, info);
        ShadowContentResolver.registerProviderInternal(info.authority, provider);
        directory = adapter((descriptor, writable) -> {
            assertTrue(descriptor.getFileDescriptor().valid());
            // Windows-hosted Robolectric has no Android /proc filesystem.
            // Return the fixture's actual backing file only for framework tests.
            return provider.lastOpened.file.getPath();
        });
    }
    private ReceiveDirectory adapter(ReceiveDirectory.DescriptorAccess access) {
        return new ReceiveDirectory(activity, new MethodChannel(messenger, "test-receive-directory"), access);
    }
    @After public void cleanup() { directory.dispose(); activity.finish(); }

    private void allFilesGrant(boolean allowed) {
        GrantedEnvironment.allowed = allowed;
    }

    @Test @Config(sdk = 34)
    public void allFilesSettingsRequiresExplicitUserGrantBeforeDownloadsSelection() throws Exception {
        allFilesGrant(false);
        assertFalse(directory.allFilesAccess());
        try { directory.downloads(); fail("No implicit permission grant"); }
        catch (IOException expected) { assertTrue(expected.getMessage().contains("系统设置")); }
        directory.openAllFilesSettings();
        Intent intent = Shadows.shadowOf(activity).getNextStartedActivity();
        assertEquals(android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, intent.getAction());
        assertEquals("package:" + activity.getPackageName(), intent.getDataString());
        assertFalse(directory.allFilesAccess());
    }

    @Test @Config(sdk = 34)
    public void grantedDownloadsSelectionIsDirectAndTheProbeDoesNotTouchExistingFiles() throws Exception {
        allFilesGrant(true);
        File folder = new File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "GlobalSend");
        folder.mkdirs();
        File original = new File(folder, "existing.txt"); Files.write(original.toPath(), new byte[]{9,8,7});
        Map<String,Object> selected = directory.downloads();
        assertEquals(folder.getCanonicalPath(), selected.get("location"));
        assertFalse(((String) selected.get("location")).startsWith("content://"));
        assertArrayEquals(new byte[]{9,8,7}, Files.readAllBytes(original.toPath()));
        assertFalse(java.util.Arrays.stream(folder.listFiles()).anyMatch(file -> file.getName().startsWith(".globalsend-write-test-")));
        try (RandomAccessFile output = new RandomAccessFile(new File(folder, "received.part"), "rw")) {
            output.write(new byte[]{1,2}); output.seek(2); output.write(3);
        }
        assertArrayEquals(new byte[]{1,2,3}, Files.readAllBytes(new File(folder, "received.part").toPath()));
    }

    @Test @Config(sdk = 34)
    public void physicalTreeAndLeafPathsRequireGrantAndNeverMapOtherProvidersOrEscapeTheVolume() throws Exception {
        Uri tree = DocumentsContract.buildTreeDocumentUri("com.android.externalstorage.documents", "primary:Download/GlobalSend");
        allFilesGrant(false);
        assertNull(directory.physicalDocument(tree));
        allFilesGrant(true);
        File expected = new File(Environment.getExternalStorageDirectory(), "Download/GlobalSend").getCanonicalFile();
        assertEquals(expected, directory.physicalDocument(tree));
        Uri leaf = DocumentsContract.buildDocumentUriUsingTree(tree, "primary:Download/GlobalSend/file.part");
        assertEquals(new File(expected, "file.part"), directory.physicalDocument(leaf));
        assertNull(directory.physicalDocument(DocumentsContract.buildTreeDocumentUri("receive-fixtures", "primary:Download/GlobalSend")));
        try {
            directory.physicalDocument(DocumentsContract.buildTreeDocumentUri("com.android.externalstorage.documents", "primary:../outside"));
            fail("The selected volume must remain the actual destination");
        } catch (IOException expectedError) { assertTrue(expectedError.getMessage().contains("存储设备")); }
    }

    @Test @Config(sdk = 34)
    public void procDescriptorPermissionFailureCanResumeTheSameAuthorizedLocalFileWithoutCopying() throws Exception {
        allFilesGrant(true);
        File folder = new File(Environment.getExternalStorageDirectory(), "Download/GlobalSend"); folder.mkdirs();
        String name = "resume-" + UUID.randomUUID() + ".part";
        File target = new File(folder, name); Files.write(target.toPath(), new byte[]{1,2});
        String id = "primary:Download/GlobalSend/" + name;
        provider = new FixtureDocuments(); provider.folder = folder;
        provider.rootId = "primary:Download/GlobalSend";
        ProviderInfo info = new ProviderInfo(); info.authority = "com.android.externalstorage.documents";
        info.exported = true; info.grantUriPermissions = true;
        info.readPermission = Manifest.permission.MANAGE_DOCUMENTS; info.writePermission = Manifest.permission.MANAGE_DOCUMENTS;
        provider.attachInfo(activity, info);
        provider.documents.put(id, new Entry(id, target, name));
        ShadowContentResolver.registerProviderInternal("com.android.externalstorage.documents", provider);
        Uri tree = DocumentsContract.buildTreeDocumentUri("com.android.externalstorage.documents", "primary:Download/GlobalSend");
        String location = DocumentsContract.buildDocumentUriUsingTree(tree, id).toString();
        activity.getSharedPreferences("globalsend-receive-destination", Activity.MODE_PRIVATE).edit()
            .putStringSet("created-document-uris", new java.util.HashSet<>(java.util.Collections.singleton(location))).commit();
        directory.dispose();
        directory = adapter((descriptor, writable) -> { throw new android.system.ErrnoException("open", android.system.OsConstants.EACCES); });
        Map<String,Object> handle = directory.open(location, true);
        assertEquals(location, handle.get("location"));
        assertEquals(target.getCanonicalPath(), handle.get("ioPath"));
        assertEquals(2L, handle.get("size"));
        try (RandomAccessFile output = new RandomAccessFile((String) handle.get("ioPath"), "rw")) {
            output.seek(2); output.write(3);
        }
        directory.close((String) handle.get("handle"), null);
        assertArrayEquals(new byte[]{1,2,3}, Files.readAllBytes(target.toPath()));
        assertFalse(provider.lastDescriptor.getFileDescriptor().valid());
        assertFalse(new File(activity.getFilesDir(), "received").exists());
    }

    @Test public void pickerUsesSystemTreeAndCancellationNeverSelectsAFolder() {
        Result pending = new Result(); directory.pick(pending);
        Intent launched = Shadows.shadowOf(activity).getNextStartedActivityForResult().intent;
        assertEquals(Intent.ACTION_OPEN_DOCUMENT_TREE, launched.getAction());
        assertTrue(launched.getBooleanExtra(Intent.EXTRA_LOCAL_ONLY, false));
        assertTrue((launched.getFlags() & Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION) != 0);
        assertTrue((launched.getFlags() & Intent.FLAG_GRANT_WRITE_URI_PERMISSION) != 0);
        Result duplicate = new Result(); directory.pick(duplicate);
        assertEquals("DIRECTORY_PICK_PENDING", duplicate.error);
        assertFalse(directory.onActivityResult(123, Activity.RESULT_CANCELED, null));
        assertEquals(0, pending.calls);
        assertTrue(directory.onActivityResult(ReceiveDirectory.PICK_DIRECTORY, Activity.RESULT_CANCELED, null));
        assertEquals(1, pending.calls); assertNull(pending.value); assertNull(pending.error);
        Result next = new Result(); directory.pick(next);
        directory.dispose(); assertEquals(1, next.calls); assertEquals("DIRECTORY_PICKER_CLOSED", next.error);
        directory.onActivityResult(ReceiveDirectory.PICK_DIRECTORY, Activity.RESULT_OK, new Intent().setData(tree));
        assertEquals(1, next.calls);
    }

    @Test public void pickerPersistsReadWriteGrantAndReturnsCanonicalTreeIdentity() throws Exception {
        Result result = new Result(); directory.pick(result);
        directory.onActivityResult(ReceiveDirectory.PICK_DIRECTORY, Activity.RESULT_OK, new Intent().setData(tree)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION));
        await(result);
        assertNull(result.error);
        Map<?, ?> selection = (Map<?, ?>) result.value;
        assertEquals(tree.toString(), selection.get("location"));
        assertEquals("我的接收目录", selection.get("label"));
        assertTrue(activity.getContentResolver().getPersistedUriPermissions().stream().anyMatch(permission ->
            permission.getUri().equals(tree) && permission.isReadPermission() && permission.isWritePermission()));
        assertNotSame(Thread.currentThread(), provider.lastQueryThread);
        assertTrue(provider.documents.isEmpty());
        assertFalse(provider.lastDescriptor.getFileDescriptor().valid());
        assertFalse(ReceiveDirectory.isOwned(activity, provider.lastCreated.toString()));
    }

    @Test public void selectionRejectsUnsupportedDescriptorBeforeSavingAndRemovesItsProbe() throws Exception {
        Entry original = provider.add("原文件.txt", new byte[]{9});
        directory.dispose();
        directory = adapter((descriptor, writable) -> { throw new IOException("Unsupported proc FD reopen"); });
        Result result = new Result(); directory.pick(result);
        directory.onActivityResult(ReceiveDirectory.PICK_DIRECTORY, Activity.RESULT_OK, new Intent().setData(tree)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION));
        await(result);
        assertEquals("RECEIVE_DIRECTORY", result.error); assertNull(result.value);
        assertEquals(1, provider.documents.size()); assertTrue(original.file.exists());
        assertArrayEquals(new byte[]{9}, Files.readAllBytes(original.file.toPath()));
        assertFalse(ReceiveDirectory.isOwned(activity, provider.lastCreated.toString()));
        assertFalse(provider.lastDescriptor.getFileDescriptor().valid());
    }

    @Test public void activityReplacementKeepsAnOpenReceiveLeaseAlive() throws Exception {
        Map<String,Object> opened = directory.create(tree.toString(), "background.txt");
        FileDescriptor descriptor = provider.lastDescriptor.getFileDescriptor();
        directory.detach(activity);
        activity.finish();
        assertTrue(descriptor.valid());
        try (RandomAccessFile output = new RandomAccessFile((String) opened.get("ioPath"), "rw")) { output.write(new byte[]{1,2,3}); }
        activity = Robolectric.buildActivity(Activity.class).setup().get();
        directory.attach(activity);
        assertEquals(3L, ((Number) directory.stat((String) opened.get("location")).get("size")).longValue());
        directory.close((String) opened.get("handle"), null);
        assertFalse(descriptor.valid());
    }

    @Test public void directReceiveResumeRenameAndDeleteOnlyTouchRegisteredDocuments() throws Exception {
        Entry original = provider.add("报告.txt", new byte[]{9, 9});
        Map<String, Object> created = directory.create(tree.toString(), "报告.txt.part");
        String location = (String) created.get("location");
        assertTrue(location.startsWith("content://"));
        assertTrue(ReceiveDirectory.isOwned(activity, location));
        FileDescriptor leasedDescriptor = provider.lastDescriptor.getFileDescriptor();
        try (RandomAccessFile output = new RandomAccessFile((String) created.get("ioPath"), "rw")) { output.write(new byte[]{1, 2}); }
        directory.close((String) created.get("handle"), null);
        assertFalse(leasedDescriptor.valid());
        directory.dispose();
        directory = adapter((descriptor, writable) -> provider.lastOpened.file.getPath());
        assertTrue(ReceiveDirectory.isOwned(activity, location));
        Map<String, Object> resumed = directory.open(location, true);
        assertEquals(2L, ((Number) resumed.get("size")).longValue());
        try (RandomAccessFile output = new RandomAccessFile((String) resumed.get("ioPath"), "rw")) { output.seek(2); output.write(3); }
        directory.close((String) resumed.get("handle"), null);
        Map<String, Object> renamed = directory.rename(location, "报告.txt");
        assertEquals("报告 (1).txt", renamed.get("name"));
        String finalLocation = (String) renamed.get("location");
        assertEquals(3L, ((Number) renamed.get("size")).longValue());
        assertArrayEquals(new byte[]{9, 9}, Files.readAllBytes(original.file.toPath()));
        assertArrayEquals(new byte[]{1, 2, 3}, Files.readAllBytes(provider.documents.get(DocumentsContract.getDocumentId(Uri.parse(finalLocation))).file.toPath()));
        String originalLocation = DocumentsContract.buildDocumentUriUsingTree(tree, original.id).toString();
        assertFalse(ReceiveDirectory.isOwned(activity, originalLocation));
        try { directory.open(originalLocation, true); fail("Existing user documents must not be resumed"); } catch (IOException expected) {}
        try { directory.delete(originalLocation); fail("Existing user documents must not be deleted"); } catch (IOException expected) {}
        assertTrue(directory.delete(finalLocation));
        assertFalse(ReceiveDirectory.isOwned(activity, finalLocation));
        assertTrue(original.file.exists());
        assertEquals(1, provider.documents.size());
    }

    @Test public void unsupportedDirectDescriptorFailsWithoutCopyFallbackOrOrphan() throws Exception {
        provider.add("已有文件.txt", new byte[]{7});
        directory.dispose();
        directory = adapter((descriptor, writable) -> { throw new IOException("Unsupported proc FD reopen"); });
        try { directory.create(tree.toString(), "new.bin"); fail("Unsupported provider must not silently copy elsewhere"); }
        catch (IOException expected) { assertTrue(expected.getMessage().contains("无法直接读写")); }
        assertEquals(1, provider.documents.size());
        assertFalse(ReceiveDirectory.isOwned(activity, provider.lastCreated.toString()));
        assertFalse(provider.lastDescriptor.getFileDescriptor().valid());
        assertFalse(new File(activity.getFilesDir(), "received").exists());
    }

    @Test public void descriptorOpeningAfterActivityDisposalCannotLeakANewLease() throws Exception {
        Map<String, Object> created = directory.create(tree.toString(), "resume.part");
        directory.close((String) created.get("handle"), null);
        directory.dispose();
        CountDownLatch opened = new CountDownLatch(1), proceed = new CountDownLatch(1);
        directory = adapter((descriptor, writable) -> {
            opened.countDown();
            if (!proceed.await(5, TimeUnit.SECONDS)) throw new IOException("Test did not release descriptor open");
            return provider.lastOpened.file.getPath();
        });
        ReceiveDirectory current = directory;
        ExecutorService worker = Executors.newSingleThreadExecutor();
        try {
            Future<Map<String, Object>> future = worker.submit(() -> current.open((String) created.get("location"), false));
            assertTrue(opened.await(5, TimeUnit.SECONDS));
            FileDescriptor raw = provider.lastDescriptor.getFileDescriptor();
            current.dispose(); proceed.countDown();
            try { future.get(5, TimeUnit.SECONDS); fail("Disposed activity must not publish a new descriptor"); }
            catch (ExecutionException expected) { assertTrue(expected.getCause() instanceof IOException); }
            assertFalse(raw.valid());
        } finally { proceed.countDown(); worker.shutdownNow(); }
    }

    private static void await(Result result) throws Exception {
        long deadline = System.currentTimeMillis() + 5000;
        while (result.calls == 0 && System.currentTimeMillis() < deadline) {
            Shadows.shadowOf(Looper.getMainLooper()).idle(); Thread.sleep(10);
        }
        assertEquals(1, result.calls);
    }
    static final class Result implements MethodChannel.Result {
        volatile int calls; Object value; String error;
        @Override public void success(Object value) { this.value = value; calls++; }
        @Override public void error(String code, String message, Object details) { error = code; calls++; }
        @Override public void notImplemented() { error = "notImplemented"; calls++; }
    }
    @Implements(Environment.class)
    public static final class GrantedEnvironment extends ShadowEnvironment {
        static boolean allowed;
        // Robolectric has no mounted FUSE volume for Environment's framework
        // implementation. Only its special-permission result is controlled;
        // production document mapping and file I/O below are exercised as-is.
        @Implementation(minSdk = 30) protected static boolean isExternalStorageManager() { return allowed; }
    }

    static final class Entry {
        final String id; final File file; String name;
        Entry(String id, File file, String name) { this.id = id; this.file = file; this.name = name; }
    }
    @Implements(DocumentsProvider.class)
    public static final class ModernDocumentQueries extends org.robolectric.shadows.ShadowContentProvider {
        @RealObject DocumentsProvider provider;
        // ShadowContentResolver directly calls the legacy provider method.
        // Real O+ binder dispatch instead forwards query arguments as a Bundle.
        @Implementation protected Cursor query(Uri uri, String[] projection, String selection, String[] args, String order) {
            return provider.query(uri, projection, android.os.Bundle.EMPTY, null);
        }
    }
    public static final class FixtureDocuments extends DocumentsProvider {
        String rootId = "selected";
        File folder; Entry lastOpened; Uri lastCreated; ParcelFileDescriptor lastDescriptor;
        Thread lastQueryThread;
        final Map<String, Entry> documents = new LinkedHashMap<>();
        @Override public boolean onCreate() { return true; }
        Entry add(String name, byte[] bytes) throws IOException {
            String id = UUID.randomUUID().toString();
            File file = new File(folder, id); Files.write(file.toPath(), bytes);
            Entry entry = new Entry(id, file, name); documents.put(id, entry); return entry;
        }
        @Override public Cursor queryRoots(String[] projection) {
            return new MatrixCursor(new String[]{DocumentsContract.Root.COLUMN_ROOT_ID, DocumentsContract.Root.COLUMN_DOCUMENT_ID});
        }
        @Override public Cursor queryDocument(String id, String[] projection) {
            lastQueryThread = Thread.currentThread();
            String[] columns = projection == null ? new String[]{DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_FLAGS} : projection;
            MatrixCursor cursor = new MatrixCursor(columns);
            if (!id.equals(rootId) && !documents.containsKey(id)) return cursor;
            Map<String, Object> data = row(id);
            Object[] values = new Object[columns.length];
            for (int i = 0; i < columns.length; i++) values[i] = data.get(columns[i]);
            cursor.addRow(values); return cursor;
        }
        @Override public Cursor queryChildDocuments(String parentId, String[] projection, String order) {
            String[] columns = projection == null ? new String[]{DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME} : projection;
            MatrixCursor cursor = new MatrixCursor(columns);
            for (Entry entry : documents.values()) {
                Map<String, Object> data = row(entry.id); Object[] values = new Object[columns.length];
                for (int i = 0; i < columns.length; i++) values[i] = data.get(columns[i]);
                cursor.addRow(values);
            }
            return cursor;
        }
        private Map<String, Object> row(String id) {
            Map<String, Object> data = new HashMap<>(); Entry entry = documents.get(id);
            data.put(DocumentsContract.Document.COLUMN_DOCUMENT_ID, id);
            data.put(DocumentsContract.Document.COLUMN_DISPLAY_NAME, entry == null ? "我的接收目录" : entry.name);
            data.put(DocumentsContract.Document.COLUMN_SIZE, entry == null ? 0 : entry.file.length());
            data.put(DocumentsContract.Document.COLUMN_MIME_TYPE, entry == null ? DocumentsContract.Document.MIME_TYPE_DIR : "application/octet-stream");
            data.put(DocumentsContract.Document.COLUMN_FLAGS, entry == null ? DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE :
                DocumentsContract.Document.FLAG_SUPPORTS_DELETE | DocumentsContract.Document.FLAG_SUPPORTS_RENAME | DocumentsContract.Document.FLAG_SUPPORTS_WRITE);
            return data;
        }
        @Override public boolean isChildDocument(String parent, String id) { return parent.equals(rootId) && documents.containsKey(id); }
        @Override public String createDocument(String parent, String mimeType, String name) throws FileNotFoundException {
            if (!parent.equals("selected") || documents.values().stream().anyMatch(entry -> entry.name.equalsIgnoreCase(name))) throw new FileNotFoundException("Name already exists");
            try {
                Entry entry = add(name, new byte[0]);
                lastCreated = DocumentsContract.buildDocumentUriUsingTree(DocumentsContract.buildTreeDocumentUri("receive-fixtures", "selected"), entry.id);
                return entry.id;
            } catch (IOException error) { throw new FileNotFoundException(error.toString()); }
        }
        @Override public String renameDocument(String id, String name) throws FileNotFoundException {
            Entry entry = documents.get(id); if (entry == null) throw new FileNotFoundException();
            if (documents.values().stream().anyMatch(other -> other != entry && other.name.equalsIgnoreCase(name))) throw new FileNotFoundException("Name already exists");
            entry.name = name; return null;
        }
        @Override public void deleteDocument(String id) throws FileNotFoundException {
            Entry entry = documents.remove(id); if (entry == null || !entry.file.delete()) throw new FileNotFoundException();
        }
        @Override public ParcelFileDescriptor openDocument(String id, String mode, CancellationSignal signal) throws FileNotFoundException {
            lastOpened = documents.get(id); if (lastOpened == null) throw new FileNotFoundException();
            lastDescriptor = ParcelFileDescriptor.open(lastOpened.file, ParcelFileDescriptor.parseMode(mode)); return lastDescriptor;
        }
    }
}
