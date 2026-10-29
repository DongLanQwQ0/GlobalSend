package dev.globalsend.globalsend;

import android.content.ContentValues;
import android.content.ContentUris;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.MediaStore;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/** Short-lived public paths for drop targets that cannot read a content stream. */
final class LegacyDragFiles {
    interface Source { InputStream open() throws IOException; }
    static final long LIFETIME_MS=600000;
    private static final String JOURNAL="drag-path-exports";
    private static final ScheduledExecutorService cleanup=Executors.newSingleThreadScheduledExecutor(job -> {
        Thread thread=new Thread(job,"GlobalSend-drag-cache");thread.setDaemon(true);return thread;
    });

    static final class Export {
        final Uri uri,readUri;final String path;
        Export(Uri uri,Uri readUri,String path){this.uri=uri;this.readUri=readUri;this.path=path;}
        void grant(Context context,String[] packages) {
            if(packages!=null)for(String name:packages) {
                context.grantUriPermission(name,uri,Intent.FLAG_GRANT_READ_URI_PERMISSION);
                // FUSE checks the typed media/file URI, not the Downloads URI
                // used to insert the same row. Both grants cover one file only.
                if(!uri.equals(readUri))context.grantUriPermission(name,readUri,Intent.FLAG_GRANT_READ_URI_PERMISSION);
            }
        }
    }

    static void restore(Context context) {
        Context app=context.getApplicationContext();
        cleanup.execute(() -> {
            for(Map.Entry<String,?> entry:app.getSharedPreferences(JOURNAL,0).getAll().entrySet())
                schedule(app,Uri.parse(entry.getKey()),(Long)entry.getValue());
        });
    }

    static Export publish(Context context,String name,String type,Source source) throws IOException {
        if(Build.VERSION.SDK_INT<29)throw new IOException("MediaStore downloads require Android 10");
        ContentValues values=new ContentValues();
        values.put(MediaStore.MediaColumns.DISPLAY_NAME,name);
        values.put(MediaStore.MediaColumns.MIME_TYPE,type);
        values.put(MediaStore.MediaColumns.RELATIVE_PATH,Environment.DIRECTORY_DOWNLOADS+"/GlobalSend/Drag-cache");
        values.put(MediaStore.MediaColumns.IS_PENDING,1);
        Uri uri=context.getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,values);
        if(uri==null)throw new IOException("Cannot allocate drag export");
        long expires=System.currentTimeMillis()+LIFETIME_MS;
        boolean published=false;
        try {
            // Record the exact inserted row before copying, so a process death
            // cannot strand an untracked public export. Never sweep a folder.
            if(!context.getSharedPreferences(JOURNAL,0).edit().putLong(uri.toString(),expires).commit())
                throw new IOException("Cannot record drag export");
            schedule(context,uri,expires);
            try(InputStream input=source.open();OutputStream output=context.getContentResolver().openOutputStream(uri,"w")) {
                if(input==null || output==null)throw new IOException("Cannot open drag export");
                byte[] bytes=new byte[65536];int count;
                while((count=input.read(bytes))!=-1)output.write(bytes,0,count);
            }
            values.clear();values.put(MediaStore.MediaColumns.IS_PENDING,0);
            context.getContentResolver().update(uri,values,null,null);
            String path;int mediaType;
            try(Cursor cursor=context.getContentResolver().query(fileAccessUri(uri,0),new String[]{MediaStore.MediaColumns.DATA,MediaStore.Files.FileColumns.MEDIA_TYPE},null,null,null)) {
                if(cursor==null || !cursor.moveToFirst() || cursor.isNull(0))throw new IOException("No exported file path");
                path=cursor.getString(0);mediaType=cursor.getInt(1);
            }
            published=true;return new Export(uri,fileAccessUri(uri,mediaType),path);
        } finally {
            if(!published) {
                context.getContentResolver().delete(uri,null,null);
                context.getSharedPreferences(JOURNAL,0).edit().remove(uri.toString()).commit();
            }
        }
    }

    static String publicPath(String path) throws IOException {
        if(path.startsWith("content://"))return null;
        File file=new File(path).getCanonicalFile();
        String root=Environment.getExternalStorageDirectory().getCanonicalPath()+File.separator;
        String actual=file.getPath();
        return actual.startsWith(root) && !actual.startsWith(root+"Android"+File.separator)?actual:null;
    }

    private static void schedule(Context context,Uri uri,long expires) {
        Context app=context.getApplicationContext();
        cleanup.schedule(() -> remove(app,uri),Math.max(0,expires-System.currentTimeMillis()),TimeUnit.MILLISECONDS);
    }
    private static Uri fileAccessUri(Uri uri,int type) {
        String volume=MediaStore.getVolumeName(uri);Uri collection;
        switch(type) {
            case MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE: collection=MediaStore.Images.Media.getContentUri(volume);break;
            case MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO: collection=MediaStore.Video.Media.getContentUri(volume);break;
            case MediaStore.Files.FileColumns.MEDIA_TYPE_AUDIO: collection=MediaStore.Audio.Media.getContentUri(volume);break;
            case MediaStore.Files.FileColumns.MEDIA_TYPE_PLAYLIST: collection=MediaStore.Audio.Playlists.getContentUri(volume);break;
            default: collection=MediaStore.Files.getContentUri(volume);
        }
        return ContentUris.withAppendedId(collection,ContentUris.parseId(uri));
    }
    static void remove(Context context,Uri uri) {
        // Only URIs returned by our own MediaStore insert enter this journal.
        if(!context.getSharedPreferences(JOURNAL,0).contains(uri.toString()))return;
        try {
            context.revokeUriPermission(uri,Intent.FLAG_GRANT_READ_URI_PERMISSION);
            // Reconstruct exact-row aliases from the existing journal after a
            // restart; never sweep directories or revoke a collection grant.
            for(int type:new int[]{0,1,2,3,4})
                context.revokeUriPermission(fileAccessUri(uri,type),Intent.FLAG_GRANT_READ_URI_PERMISSION);
            context.getContentResolver().delete(uri,null,null);
            context.getSharedPreferences(JOURNAL,0).edit().remove(uri.toString()).commit();
        } catch(RuntimeException unavailable) {
            android.util.Log.w("GlobalSend","Cannot remove expired drag export",unavailable);
        }
    }
}
