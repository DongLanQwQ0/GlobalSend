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
    private static void trace(String event) {
        if(android.util.Log.isLoggable("GlobalSendDrag",android.util.Log.DEBUG))
            android.util.Log.d("GlobalSendDrag",event+" caller="+android.os.Binder.getCallingUid());
    }
    private static final class Entry {
        final File file; final Uri source; final String original,name,mimeType;final Long size;
        final long expires = System.currentTimeMillis() + 600000;
        volatile long externalRead=-1;
        Entry(File file,Uri source,String original,String name,String type,Long size) {
            this.file=file;this.source=source;this.original=original;this.name=name;this.mimeType=type;this.size=size;
        }
    }
    private static final ConcurrentHashMap<String, Entry> entries = new ConcurrentHashMap<>();
    static Uri register(android.content.Context context, File file, String label) throws Exception {
        File canonical = file.getCanonicalFile();
        // Explicit drag/share exports require read access, not cleanup ownership.
        // A user-selected Download/GlobalSend file is not app-private, but is a
        // valid original for this same read-only URI capability.
        if (!canonical.isFile() || !canonical.canRead()) throw new SecurityException("文件不存在或无法读取");
        entries.entrySet().removeIf(e -> e.getValue().expires < System.currentTimeMillis());
        return register(context,new Entry(canonical,null,file.getPath(),label,mimeType(file.getName()),canonical.length()));
    }
    private static Uri register(android.content.Context context,Entry entry) {
        entries.entrySet().removeIf(e -> e.getValue().expires < System.currentTimeMillis());
        String id=UUID.randomUUID().toString();entries.put(id,entry);
        // A real display-name segment also supports targets that classify a
        // shared item by its URI extension rather than querying OpenableColumns.
        return new Uri.Builder().scheme("content").authority(context.getPackageName()+".dock-files")
            .appendPath("share").appendPath(id).appendPath(entry.name).build();
    }
    static Uri registerReadSource(android.content.Context context,String original) throws Exception {
        String readable=ReceiveDirectory.readableLocation(context,original);
        if(!readable.startsWith("content://")) {
            File file=new File(readable).getCanonicalFile();
            if(!file.isFile() || !file.canRead())throw new FileNotFoundException("文件不存在或无法读取");
            return register(context,new Entry(file,null,original,file.getName(),mimeType(file.getName()),file.length()));
        }
        Uri source=Uri.parse(readable);String type=context.getContentResolver().getType(source);
        if(android.provider.DocumentsContract.Document.MIME_TYPE_DIR.equals(type))return source;
        String name=source.getLastPathSegment();Long size=null;
        try(Cursor cursor=context.getContentResolver().query(source,new String[]{OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE},null,null,null)) {
            if(cursor!=null && cursor.moveToFirst()) {
                if(!cursor.isNull(0))name=cursor.getString(0);
                if(!cursor.isNull(1))size=cursor.getLong(1);
            }
        }
        if(name==null || name.isEmpty())name="shared-file";
        return register(context,new Entry(null,source,original,name,type==null?mimeType(name):type,size));
    }
    static boolean canObserveRead(String original) {
        for(Entry entry:entries.values())if(entry.original.equals(original))return true;
        return false;
    }
    static boolean wasReadSince(String original,long since) {
        for(Entry entry:entries.values())if(entry.original.equals(original) && entry.externalRead>=since)return true;
        return false;
    }
    static Uri registerForShare(android.content.Context context,File file,String label) throws Exception {
        return register(context,file,label);
    }
    private Entry lookup(Uri uri) throws FileNotFoundException {
        if (uri.getPathSegments().size() < 2 || uri.getPathSegments().size()>3 || !uri.getPathSegments().get(0).equals("share")) throw new FileNotFoundException();
        Entry entry = entries.get(uri.getPathSegments().get(1));
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
        try { String type=lookup(uri).mimeType;trace("type="+type);return type; }
        catch (FileNotFoundException error) { return null; }
    }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!mode.equals("r")) throw new FileNotFoundException("Read-only drag capability");
        Entry entry=lookup(uri);int caller=android.os.Binder.getCallingUid();
        ParcelFileDescriptor descriptor;
        if(entry.file!=null)descriptor=ParcelFileDescriptor.open(entry.file,ParcelFileDescriptor.MODE_READ_ONLY);
        else {
            // Forward the app's already-authorized document as a descriptor;
            // no byte copy and no requirement for the target to understand SAF.
            long identity=android.os.Binder.clearCallingIdentity();
            try {descriptor=getContext().getContentResolver().openFileDescriptor(entry.source,"r");}
            finally {android.os.Binder.restoreCallingIdentity(identity);}
            if(descriptor==null)throw new FileNotFoundException("无法读取共享文件");
        }
        markRead(entry,caller);
        trace("open-readable");return descriptor;
    }
    private static void markRead(Entry entry,int caller) {
        if(caller!=android.os.Process.myUid() && caller>=android.os.Process.FIRST_APPLICATION_UID)
            entry.externalRead=android.os.SystemClock.uptimeMillis();
    }
    @Override public android.content.res.AssetFileDescriptor openAssetFile(Uri uri,String mode) throws FileNotFoundException {
        if(!"r".equals(mode))throw new FileNotFoundException("Read-only drag capability");
        Entry entry=lookup(uri);if(entry.source==null)return super.openAssetFile(uri,mode);
        int caller=android.os.Binder.getCallingUid();long identity=android.os.Binder.clearCallingIdentity();
        android.content.res.AssetFileDescriptor result;
        try {result=getContext().getContentResolver().openAssetFileDescriptor(entry.source,mode);}
        finally {android.os.Binder.restoreCallingIdentity(identity);}
        if(result==null)throw new FileNotFoundException("无法读取共享文件");
        markRead(entry,caller);trace("open-asset-readable");return result;
    }
    @Override public android.content.res.AssetFileDescriptor openTypedAssetFile(Uri uri,String type,android.os.Bundle options) throws FileNotFoundException {
        Entry entry=lookup(uri);if(entry.source==null)return super.openTypedAssetFile(uri,type,options);
        int caller=android.os.Binder.getCallingUid();long identity=android.os.Binder.clearCallingIdentity();
        android.content.res.AssetFileDescriptor result;
        try {result=getContext().getContentResolver().openTypedAssetFileDescriptor(entry.source,type,options);}
        finally {android.os.Binder.restoreCallingIdentity(identity);}
        if(result==null)throw new FileNotFoundException("无法读取共享文件");
        markRead(entry,caller);trace("open-typed-readable");return result;
    }
    @Override public String[] getStreamTypes(Uri uri,String filter) {
        try {
            Entry entry=lookup(uri);
            if(entry.source==null)return android.content.ClipDescription.compareMimeTypes(entry.mimeType,filter)?new String[]{entry.mimeType}:null;
            long identity=android.os.Binder.clearCallingIdentity();
            try {return getContext().getContentResolver().getStreamTypes(entry.source,filter);}
            finally {android.os.Binder.restoreCallingIdentity(identity);}
        } catch(FileNotFoundException missing){return null;}
    }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] arguments, String order) {
        trace("query data="+(projection!=null && java.util.Arrays.asList(projection).contains("_data")));
        try {
            Entry e = lookup(uri); String[] columns = projection == null ? new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE} : projection;
            MatrixCursor cursor = new MatrixCursor(columns); Object[] values = new Object[columns.length];
            for (int i = 0; i < columns.length; i++) values[i] = columns[i].equals(OpenableColumns.DISPLAY_NAME) ? e.name : columns[i].equals(OpenableColumns.SIZE) ? (e.file!=null?Long.valueOf(e.file.length()):e.size) : null;
            cursor.addRow(values); return cursor;
        } catch (FileNotFoundException e) { return null; }
    }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] arguments) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] arguments) { throw new UnsupportedOperationException(); }
}
