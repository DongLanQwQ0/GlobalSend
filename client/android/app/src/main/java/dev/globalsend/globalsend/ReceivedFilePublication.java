package dev.globalsend.globalsend;

import android.content.Context;
import android.media.MediaScannerConnection;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.os.storage.StorageManager;
import android.os.storage.StorageVolume;
import android.provider.DocumentsContract;
import android.util.Log;
import java.io.File;
import java.io.IOException;

/** Publish completed shared-storage files, including non-media Downloads. No copy or move. */
final class ReceivedFilePublication {
    static boolean publish(Context context, String location,
            MediaScannerConnection.OnScanCompletedListener completed) throws IOException {
        File file = sharedFile(context, location);
        if (file == null) return false;
        // Use the final name: scanning the .part file records the wrong type/path.
        // The scanner updates MediaStore.Files/Downloads as well as media collections.
        MediaScannerConnection.scanFile(context, new String[]{file.getPath()}, null, (path, uri) -> {
            if (uri == null) Log.w("GlobalSendPublish", "System did not index completed file: " + path);
            if (completed != null) completed.onScanCompleted(path, uri);
        });
        return true;
    }

    static File sharedFile(Context context, String location) throws IOException {
        File file;
        if (location.startsWith("content://")) {
            Uri document = Uri.parse(location);
            // Other document providers own their publication; never guess cloud paths.
            if (!"com.android.externalstorage.documents".equals(document.getAuthority())) return null;
            if (DocumentsContract.Document.MIME_TYPE_DIR.equals(context.getContentResolver().getType(document))) return null;
            String id = DocumentsContract.getDocumentId(document);
            int split = id.indexOf(':');
            if (split < 0) return null;
            File root = volumeRoot(context, id.substring(0, split));
            if (root == null) return null;
            file = new File(root, id.substring(split + 1)).getCanonicalFile();
            if (!inside(file, root.getCanonicalFile())) return null;
        } else {
            file = new File(location).getCanonicalFile();
            if (!file.isFile()) return null;
        }
        for (StorageVolume volume : context.getSystemService(StorageManager.class).getStorageVolumes()) {
            File root = volume.isPrimary() ? Environment.getExternalStorageDirectory()
                    : Build.VERSION.SDK_INT >= 30 ? volume.getDirectory() : null;
            if (root == null || !inside(file, root.getCanonicalFile())) continue;
            String relative = file.getPath().substring(root.getCanonicalPath().length() + 1).replace(File.separatorChar, '/');
            // App-private external data is intentionally not exposed in file pickers.
            if (relative.startsWith("Android/data/") || relative.startsWith("Android/obb/")) return null;
            return file;
        }
        return null;
    }

    private static File volumeRoot(Context context, String id) {
        if ("primary".equalsIgnoreCase(id)) return Environment.getExternalStorageDirectory();
        if (Build.VERSION.SDK_INT >= 30) {
            for (StorageVolume volume : context.getSystemService(StorageManager.class).getStorageVolumes()) {
                if (id.equalsIgnoreCase(volume.getUuid())) return volume.getDirectory();
            }
        }
        return null;
    }

    private static boolean inside(File file, File root) {
        return file.getPath().startsWith(root.getPath() + File.separator);
    }
}
