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
        remember(context,file);
        // Use the final name: scanning the .part file records the wrong type/path.
        // The scanner updates MediaStore.Files/Downloads as well as media collections.
        MediaScannerConnection.scanFile(context, new String[]{file.getPath()}, null, (path, uri) -> {
            if (uri == null) Log.w("GlobalSendPublish", "System did not index completed file: " + path);
            if (completed != null) completed.onScanCompleted(path, uri);
        });
        return true;
    }

    // Record before scanning: the media observer may run before onScanCompleted.
    // Paths, rather than display names or a whole receive folder, distinguish
    // our receipts/exports from unrelated camera files in the same destination.
    private static final Object RECEIPTS_LOCK=new Object();
    static void remember(Context context,File file) throws IOException {
        synchronized(RECEIPTS_LOCK) {
            var state=context.getSharedPreferences("received-media-origins",Context.MODE_PRIVATE);
            var paths=new java.util.HashSet<>(state.getStringSet("paths",java.util.Set.of()));
            if(paths.add(file.getCanonicalPath()))state.edit().putStringSet("paths",paths).apply();
        }
    }
    static java.util.Set<String> receivedPaths(Context context) {
        synchronized(RECEIPTS_LOCK) {
            return new java.util.HashSet<>(context.getSharedPreferences("received-media-origins",Context.MODE_PRIVATE)
                .getStringSet("paths",java.util.Set.of()));
        }
    }

    /** Media created by this application is not a new camera/media recommendation. */
    static boolean applicationMedia(Context context,String path,String owner,String relativePath,
            java.util.Set<String> recorded) {
        if(context.getPackageName().equals(owner))return true;
        if(path!=null) {
            File file=new File(path);
            try {file=file.getCanonicalFile();} catch(IOException unavailable) {file=file.getAbsoluteFile();}
            if(recorded.contains(file.getPath()))return true;
            if(inside(file,context.getFilesDir().getParentFile()) || inside(file,context.getCacheDir()))return true;
            for(File root:context.getExternalFilesDirs(null))if(root!=null && inside(file,root.getParentFile()))return true;
            for(File root:context.getExternalCacheDirs())if(root!=null && inside(file,root))return true;
            String root=Environment.getExternalStorageDirectory().getAbsolutePath()+File.separator;
            if(file.getPath().startsWith(root))relativePath=file.getPath().substring(root.length());
        }
        // Also catch exports made by an older build, or rows whose DATA is
        // redacted. This is the app's one reserved public compatibility cache,
        // not the chosen receive folder and not arbitrary folders called cache.
        if(relativePath==null)return false;
        String relative=relativePath.replace('\\','/').toLowerCase(java.util.Locale.ROOT);
        String prefix=Environment.DIRECTORY_DOWNLOADS.toLowerCase(java.util.Locale.ROOT)+"/globalsend/";
        return relative.startsWith(prefix+"drag-cache/") || relative.equals(prefix+"drag-cache") ||
            relative.startsWith(prefix+"dragcache/") || relative.equals(prefix+"dragcache");
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
