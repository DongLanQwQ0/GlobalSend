package dev.globalsend.globalsend;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import android.webkit.MimeTypeMap;
import java.io.File;
import java.io.FileNotFoundException;
import java.util.UUID;
import java.util.Locale;
import java.util.concurrent.ConcurrentHashMap;

/** Read-only, unguessable, short-lived capabilities for explicit cross-app drag gestures. */
public final class DockShareProvider extends ContentProvider {
    private static final class Entry {
        final File file; final String name; final String mimeType; final long expires = System.currentTimeMillis() + 600000;
        Entry(File file, String name) { this.file = file; this.name = name; this.mimeType = mimeType(file.getName()); }
    }
    private static final ConcurrentHashMap<String, Entry> entries = new ConcurrentHashMap<>();
    static Uri register(android.content.Context context, File file, String label) throws Exception {
        return register(context,file,label,true);
    }
    static Uri registerForShare(android.content.Context context,File file,String label) throws Exception {
        return register(context,file,label,false);
    }
    private static Uri register(android.content.Context context, File file, String label,boolean requireOwned) throws Exception {
        File canonical = file.getCanonicalFile();
        String path = canonical.getPath(), data = context.getDataDir().getCanonicalPath() + File.separator;
        File external = context.getExternalFilesDir(null);
        boolean allowed = path.startsWith(data) || (external != null && path.startsWith(external.getCanonicalPath() + File.separator));
        if ((requireOwned&&!allowed) || !canonical.isFile() || !canonical.canRead()) throw new SecurityException("文件不存在或无法读取");
        entries.entrySet().removeIf(e -> e.getValue().expires < System.currentTimeMillis());
        String id = UUID.randomUUID().toString(); entries.put(id, new Entry(canonical, label));
        return new Uri.Builder().scheme("content").authority(context.getPackageName() + ".dock-files").appendPath("share").appendPath(id).build();
    }
    private Entry lookup(Uri uri) throws FileNotFoundException {
        if (uri.getPathSegments().size() != 2 || !uri.getPathSegments().get(0).equals("share")) throw new FileNotFoundException();
        Entry entry = entries.get(uri.getLastPathSegment());
        if (entry == null || entry.expires < System.currentTimeMillis()) throw new FileNotFoundException("Drag authorization expired; drag again");
        return entry;
    }
    @Override public boolean onCreate() { return true; }
    static String mimeType(String name) {
        int dot = name.lastIndexOf('.');
        String type = dot < 0 ? null : MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substring(dot + 1).toLowerCase(Locale.ROOT));
        return type == null ? "application/octet-stream" : type;
    }
    @Override public String getType(Uri uri) {
        try { return lookup(uri).mimeType; }
        catch (FileNotFoundException error) { return null; }
    }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!mode.equals("r")) throw new FileNotFoundException("Read-only drag capability");
        return ParcelFileDescriptor.open(lookup(uri).file, ParcelFileDescriptor.MODE_READ_ONLY);
    }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] arguments, String order) {
        try {
            Entry e = lookup(uri); String[] columns = projection == null ? new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE} : projection;
            MatrixCursor cursor = new MatrixCursor(columns); Object[] values = new Object[columns.length];
            for (int i = 0; i < columns.length; i++) values[i] = columns[i].equals(OpenableColumns.DISPLAY_NAME) ? e.name : columns[i].equals(OpenableColumns.SIZE) ? e.file.length() : null;
            cursor.addRow(values); return cursor;
        } catch (FileNotFoundException e) { return null; }
    }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] arguments) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] arguments) { throw new UnsupportedOperationException(); }
}
