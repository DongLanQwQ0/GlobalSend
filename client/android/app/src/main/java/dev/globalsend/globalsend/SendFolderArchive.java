package dev.globalsend.globalsend;

import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.provider.DocumentsContract;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

/** One streaming transfer archive; originals remain with the selected provider. */
final class SendFolderArchive {
    static Map<String, String> create(Context context, Uri selected) throws Exception {
        boolean tree = DocumentsContract.isTreeUri(selected);
        String id = DocumentsContract.isDocumentUri(context, selected)
            ? DocumentsContract.getDocumentId(selected) : DocumentsContract.getTreeDocumentId(selected);
        Uri document = tree ? DocumentsContract.buildDocumentUriUsingTree(selected, id) : selected;
        String name;
        try (Cursor cursor = context.getContentResolver().query(document,
                new String[]{DocumentsContract.Document.COLUMN_DISPLAY_NAME}, null, null, null)) {
            if (cursor == null || !cursor.moveToFirst()) throw new IOException("文件夹已不存在");
            name = cursor.getString(0);
        }
        String safeName = name.replaceAll("[\\\\/:*?\"<>|\\p{Cntrl}]", "_");
        File folder = new File(context.getFilesDir(), "outgoing-folders/" + UUID.randomUUID());
        if (!folder.mkdirs()) throw new IOException("无法准备文件夹");
        File output = new File(folder, safeName + ".zip");
        try (ZipOutputStream zip = new ZipOutputStream(new FileOutputStream(output))) {
            addDirectory(context, selected, id, safeName + "/", zip);
        } catch (Exception error) {
            output.delete(); folder.delete(); throw error;
        }
        Map<String, String> value = new HashMap<>();
        value.put("path", output.getAbsolutePath()); value.put("name", name); value.put("source", document.toString());
        return value;
    }

    private static void addDirectory(Context context, Uri root, String parentId, String path, ZipOutputStream zip) throws Exception {
        zip.putNextEntry(new ZipEntry(path)); zip.closeEntry();
        Uri children = DocumentsContract.isTreeUri(root)
            ? DocumentsContract.buildChildDocumentsUriUsingTree(root, parentId)
            : DocumentsContract.buildChildDocumentsUri(root.getAuthority(), parentId);
        try (Cursor cursor = context.getContentResolver().query(children, new String[]{
                DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE}, null, null, null)) {
            if (cursor == null) throw new IOException("无法读取文件夹");
            byte[] buffer = new byte[64 * 1024];
            while (cursor.moveToNext()) {
                if (Thread.currentThread().isInterrupted()) throw new IOException("已停止打包");
                String id = cursor.getString(0), name = cursor.getString(1).replace('/', '_').replace('\\', '_');
                if (DocumentsContract.Document.MIME_TYPE_DIR.equals(cursor.getString(2))) {
                    addDirectory(context, root, id, path + name + "/", zip);
                } else {
                    Uri document = DocumentsContract.isTreeUri(root)
                        ? DocumentsContract.buildDocumentUriUsingTree(root, id)
                        : DocumentsContract.buildDocumentUri(root.getAuthority(), id);
                    zip.putNextEntry(new ZipEntry(path + name));
                    try (InputStream input = context.getContentResolver().openInputStream(document)) {
                        if (input == null) throw new IOException("无法读取 " + name);
                        int count;
                        while ((count = input.read(buffer)) != -1) zip.write(buffer, 0, count);
                    }
                    zip.closeEntry();
                }
            }
        }
    }
}
