package dev.globalsend.globalsend;

import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.provider.DocumentsContract;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Enumerates provider documents without reading or copying their contents. */
final class SendFolderEntries {
    static Map<String, String> selection(Context context, Uri selected) throws Exception {
        Uri document = document(selected, rootId(context, selected));
        try (Cursor cursor = context.getContentResolver().query(document,
                new String[]{DocumentsContract.Document.COLUMN_DISPLAY_NAME}, null, null, null)) {
            if (cursor == null || !cursor.moveToFirst()) throw new IOException("文件夹已不存在");
            Map<String, String> value = new HashMap<>();
            value.put("source", document.toString()); value.put("name", cursor.getString(0));
            return value;
        }
    }
    static List<Map<String, Object>> read(Context context, Uri root) throws Exception {
        Map<String, String> selection = selection(context, root);
        List<Map<String, Object>> result = new ArrayList<>();
        visit(context, root, rootId(context, root), selection.get("name"), result);
        return result;
    }
    private static String rootId(Context context, Uri root) {
        try { return DocumentsContract.getDocumentId(root); }
        catch (IllegalArgumentException treeOnly) { return DocumentsContract.getTreeDocumentId(root); }
    }
    private static Uri document(Uri root, String id) {
        return DocumentsContract.isTreeUri(root) ? DocumentsContract.buildDocumentUriUsingTree(root, id) : DocumentsContract.buildDocumentUri(root.getAuthority(), id);
    }
    private static void visit(Context context, Uri root, String parentId, String path, List<Map<String, Object>> result) throws Exception {
        add(result, document(root, parentId), path, true);
        Uri children = DocumentsContract.isTreeUri(root) ? DocumentsContract.buildChildDocumentsUriUsingTree(root, parentId) : DocumentsContract.buildChildDocumentsUri(root.getAuthority(), parentId);
        try (Cursor cursor = context.getContentResolver().query(children, new String[]{DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE}, null, null, null)) {
            if (cursor == null) throw new IOException("无法读取文件夹");
            while (cursor.moveToNext()) {
                if (Thread.currentThread().isInterrupted()) throw new IOException("已停止读取文件夹");
                String id = cursor.getString(0), leaf = cursor.getString(1);
                if (leaf.contains("/") || leaf.contains("\\") || leaf.equals(".") || leaf.equals("..")) throw new IOException("文件夹包含无法传输的名称");
                if (DocumentsContract.Document.MIME_TYPE_DIR.equals(cursor.getString(2))) visit(context, root, id, path + "/" + leaf, result);
                else add(result, document(root, id), path + "/" + leaf, false);
            }
        }
    }
    private static void add(List<Map<String, Object>> result, Uri location, String relative, boolean directory) throws IOException {
        if (result.size() >= 10000) throw new IOException("文件夹超过 10000 项，请拆分后发送");
        Map<String, Object> item = new HashMap<>();
        item.put("location", location.toString()); item.put("relativePath", relative); item.put("entryKind", directory ? "directory" : "file");
        result.add(item);
    }
}
