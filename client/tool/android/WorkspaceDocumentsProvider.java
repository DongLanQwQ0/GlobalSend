package dev.globalsend.globalsend;

import android.database.Cursor;
import android.database.MatrixCursor;
import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.provider.DocumentsProvider;
import java.io.File;
import java.io.FileNotFoundException;
import java.util.HashMap;
import java.util.Map;

/** Local synthetic SAF tree for the UI-only runtime check. */
public final class WorkspaceDocumentsProvider extends DocumentsProvider {
    static File source(android.content.Context context) { return new File(context.getFilesDir(), "source-fixture/资料"); }
    private File file(String id) throws FileNotFoundException {
        File root = source(getContext());
        if ("root".equals(id)) return root;
        if (!id.startsWith("root/")) throw new FileNotFoundException(id);
        return new File(root, id.substring(5));
    }
    @Override public boolean onCreate() { return true; }
    @Override public Cursor queryRoots(String[] projection) {
        String[] columns = projection == null ? new String[]{DocumentsContract.Root.COLUMN_ROOT_ID,
            DocumentsContract.Root.COLUMN_TITLE, DocumentsContract.Root.COLUMN_DOCUMENT_ID,
            DocumentsContract.Root.COLUMN_FLAGS, DocumentsContract.Root.COLUMN_MIME_TYPES,
            DocumentsContract.Root.COLUMN_AVAILABLE_BYTES} : projection;
        MatrixCursor cursor = new MatrixCursor(columns);
        Map<String, Object> values = new HashMap<>();
        values.put(DocumentsContract.Root.COLUMN_ROOT_ID, "fixture");
        values.put(DocumentsContract.Root.COLUMN_TITLE, "GlobalSend UI fixtures");
        values.put(DocumentsContract.Root.COLUMN_DOCUMENT_ID, "root");
        values.put(DocumentsContract.Root.COLUMN_FLAGS, DocumentsContract.Root.FLAG_LOCAL_ONLY | DocumentsContract.Root.FLAG_SUPPORTS_IS_CHILD);
        values.put(DocumentsContract.Root.COLUMN_MIME_TYPES, "*/*");
        values.put(DocumentsContract.Root.COLUMN_AVAILABLE_BYTES, 1024L * 1024 * 1024);
        add(cursor, columns, values); return cursor;
    }
    private static void add(MatrixCursor cursor, String[] columns, Map<String, Object> values) {
        Object[] row = new Object[columns.length];
        for (int i = 0; i < columns.length; i++) row[i] = values.get(columns[i]);
        cursor.addRow(row);
    }
    private MatrixCursor documents(String[] projection) {
        return new MatrixCursor(projection == null ? new String[]{DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_FLAGS, DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED} : projection);
    }
    private void document(MatrixCursor cursor, String id, File file) {
        Map<String, Object> values = new HashMap<>();
        values.put(DocumentsContract.Document.COLUMN_DOCUMENT_ID, id);
        values.put(DocumentsContract.Document.COLUMN_DISPLAY_NAME, file.getName());
        values.put(DocumentsContract.Document.COLUMN_MIME_TYPE, file.isDirectory() ? DocumentsContract.Document.MIME_TYPE_DIR : DockShareProvider.mimeType(file.getName()));
        values.put(DocumentsContract.Document.COLUMN_FLAGS, 0);
        values.put(DocumentsContract.Document.COLUMN_SIZE, file.length());
        values.put(DocumentsContract.Document.COLUMN_LAST_MODIFIED, file.lastModified());
        add(cursor, cursor.getColumnNames(), values);
    }
    @Override public Cursor queryDocument(String id, String[] projection) throws FileNotFoundException {
        File file = file(id); if (!file.exists()) throw new FileNotFoundException(id);
        MatrixCursor cursor = documents(projection); document(cursor, id, file); return cursor;
    }
    @Override public Cursor queryChildDocuments(String id, String[] projection, String order) throws FileNotFoundException {
        MatrixCursor cursor = documents(projection); File[] children = file(id).listFiles();
        if (children == null) throw new FileNotFoundException(id);
        java.util.Arrays.sort(children, java.util.Comparator.comparing(File::getName));
        for (File child : children) document(cursor, id + "/" + child.getName(), child);
        return cursor;
    }
    @Override public ParcelFileDescriptor openDocument(String id, String mode, CancellationSignal signal) throws FileNotFoundException {
        return ParcelFileDescriptor.open(file(id), ParcelFileDescriptor.MODE_READ_ONLY);
    }
    @Override public boolean isChildDocument(String parent, String child) { return child.startsWith(parent + "/"); }
}
