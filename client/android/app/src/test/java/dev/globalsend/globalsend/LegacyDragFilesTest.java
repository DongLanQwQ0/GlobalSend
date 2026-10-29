package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.ProviderInfo;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.File;
import java.io.FileNotFoundException;
import java.nio.file.Files;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.Executors;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowBinder;
import org.robolectric.shadows.ShadowContentResolver;

@RunWith(RobolectricTestRunner.class)
@Config(sdk=34,manifest=Config.NONE)
public class LegacyDragFilesTest {
    private static final int TARGET=10362;
    private final Context context=RuntimeEnvironment.getApplication();
    private DockShareProvider provider;
    private Media media;
    private void setup() {
        PackageInfo target=new PackageInfo();target.packageName="com.tencent.mm";target.applicationInfo=new ApplicationInfo();
        target.applicationInfo.packageName=target.packageName;target.applicationInfo.uid=TARGET;
        Shadows.shadowOf(context.getPackageManager()).installPackage(target);
        media=new Media();ProviderInfo storage=new ProviderInfo();storage.authority="media";media.attachInfo(context,storage);
        ShadowContentResolver.registerProviderInternal("media",media);
        provider=new DockShareProvider();ProviderInfo info=new ProviderInfo();info.authority=context.getPackageName()+".dock-files";
        provider.attachInfo(context,info);ShadowContentResolver.registerProviderInternal(info.authority,provider);
    }
    private Cursor externalQuery(Uri uri,String[] columns) throws Exception {
        var worker=Executors.newSingleThreadExecutor();
        try {return worker.submit(() -> {ShadowBinder.setCallingUid(TARGET);return provider.query(uri,columns,null,null,null);}).get();}
        finally {worker.shutdownNow();}
    }
    @Test public void nullProjectionLegacyReaderGetsReusableRealPathAndOnlyOwnedCopyIsCleaned() throws Exception {
        setup();File original=new File(context.getFilesDir(),"image.png");byte[] bytes={3,1,4,1,5};Files.write(original.toPath(),bytes);
        Uri uri=DockShareProvider.registerReadSource(context,original.getPath());
        // Metadata reads in our own UI must not perform a file copy.
        ShadowBinder.setCallingUid(android.os.Process.myUid());
        try(Cursor own=provider.query(uri,null,null,null,null)){assertTrue(own.moveToFirst());assertTrue(own.isNull(own.getColumnIndexOrThrow("_data")));}
        assertEquals(0,media.inserted);long started=android.os.SystemClock.uptimeMillis();
        String path;
        try(Cursor cursor=externalQuery(uri,null)) {
            assertTrue(cursor.moveToFirst());path=cursor.getString(cursor.getColumnIndexOrThrow("_data"));
            assertEquals(original.getName(),cursor.getString(cursor.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME)));
        }
        assertNotEquals(original.getPath(),path);assertArrayEquals(bytes,Files.readAllBytes(new File(path).toPath()));
        assertEquals(1,media.inserted);assertFalse(media.copyThread.contains("main"));
        try(Cursor again=externalQuery(uri,null)){assertTrue(again.moveToFirst());assertEquals(path,again.getString(again.getColumnIndexOrThrow("_data")));}
        assertEquals(1,media.inserted);assertTrue(DockShareProvider.wasAccessedSince(original.getPath(),started));
        LegacyDragFiles.remove(context,media.last);
        assertEquals(1,media.deleted);assertFalse(new File(path).exists());assertArrayEquals(bytes,Files.readAllBytes(original.toPath()));
    }
    @Test public void publicOriginalUsesItsExistingPathWithoutCreatingAnotherFile() throws Exception {
        setup();File original=new File(android.os.Environment.getExternalStorageDirectory(),"Download/existing.jpg");
        assertTrue(original.getParentFile().mkdirs() || original.getParentFile().isDirectory());Files.write(original.toPath(),new byte[]{1,2,3});
        Uri uri=DockShareProvider.registerReadSource(context,original.getPath());
        try(Cursor cursor=externalQuery(uri,null)){assertTrue(cursor.moveToFirst());assertEquals(original.getCanonicalPath(),cursor.getString(cursor.getColumnIndexOrThrow("_data")));}
        assertEquals(0,media.inserted);assertTrue(original.exists());
    }
    @Test public void failedPublicExportDoesNotAcknowledgeOrDeleteTheOriginal() throws Exception {
        setup();media.failOutput=true;File original=new File(context.getFilesDir(),"retry.png");Files.write(original.toPath(),new byte[]{2,7});
        Uri uri=DockShareProvider.registerReadSource(context,original.getPath());long started=android.os.SystemClock.uptimeMillis();
        assertNull(externalQuery(uri,null));assertEquals(1,media.deleted);
        assertFalse(DockShareProvider.wasAccessedSince(original.getPath(),started));assertTrue(original.exists());
        assertTrue(context.getSharedPreferences("drag-path-exports",0).getAll().isEmpty());
    }
    @Test public void mediaStoreOriginalKeepsItsPublicPathWithoutAnotherExport() throws Exception {
        setup();File original=new File(android.os.Environment.getExternalStorageDirectory(),"Download/media-original.png");
        assertTrue(original.getParentFile().mkdirs() || original.getParentFile().isDirectory());Files.write(original.toPath(),new byte[]{5,8});
        Uri mediaUri=Uri.parse("content://media/external/images/media/77");media.files.put(mediaUri,original);
        Uri uri=DockShareProvider.registerReadSource(context,mediaUri.toString());
        try(Cursor cursor=externalQuery(uri,null)){assertTrue(cursor.moveToFirst());assertEquals(original.getCanonicalPath(),cursor.getString(cursor.getColumnIndexOrThrow("_data")));}
        assertEquals(0,media.inserted);assertTrue(original.exists());
    }
    @Test public void explicitOpenableColumnsDoNotTriggerLegacyPreparation() throws Exception {
        setup();File original=new File(context.getFilesDir(),"ordinary.png");Files.write(original.toPath(),new byte[]{1});
        Uri uri=DockShareProvider.registerReadSource(context,original.getPath());
        try(Cursor cursor=externalQuery(uri,new String[]{OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE})) {
            assertTrue(cursor.moveToFirst());assertEquals(2,cursor.getColumnCount());
        }
        assertEquals(0,media.inserted);
    }
    @Test public void legacyExportKeepsAnAssetOnlyDocumentsSliceNotTheBackingFile() throws Exception {
        setup();AndroidDragTest.FixtureProvider document=new AndroidDragTest.FixtureProvider() {
            @Override public String getType(Uri uri){return "image/png";}
            @Override public ParcelFileDescriptor openFile(Uri uri,String mode) throws FileNotFoundException {throw new FileNotFoundException("asset only");}
            @Override public android.content.res.AssetFileDescriptor openAssetFile(Uri uri,String mode) throws FileNotFoundException {
                return new android.content.res.AssetFileDescriptor(ParcelFileDescriptor.open(new File(directory,uri.getLastPathSegment()),ParcelFileDescriptor.MODE_READ_ONLY),2,3);
            }
        };
        document.directory=new File(context.getFilesDir(),"legacy-asset");assertTrue(document.directory.mkdirs());
        File original=new File(document.directory,"slice.png");Files.write(original.toPath(),new byte[]{9,9,3,1,4,8});
        ProviderInfo info=new ProviderInfo();info.authority="legacy-document";document.attachInfo(context,info);
        ShadowContentResolver.registerProviderInternal(info.authority,document);
        Uri uri=DockShareProvider.registerReadSource(context,"content://legacy-document/slice.png");
        try(Cursor cursor=externalQuery(uri,null)) {
            assertTrue(cursor.moveToFirst());String path=cursor.getString(cursor.getColumnIndexOrThrow("_data"));
            assertArrayEquals(new byte[]{3,1,4},Files.readAllBytes(new File(path).toPath()));
        }
        assertArrayEquals(new byte[]{9,9,3,1,4,8},Files.readAllBytes(original.toPath()));
        LegacyDragFiles.remove(context,media.last);
    }
    @Test public void realPathGrantIncludesOnlyTheSameRowsTypedUriAndCleanupRevokesIt() throws Exception {
        setup();java.util.List<Uri> granted=new java.util.ArrayList<>(),revoked=new java.util.ArrayList<>();
        Context captures=new android.content.ContextWrapper(context) {
            @Override public void grantUriPermission(String target,Uri uri,int flags){assertEquals(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION,flags);granted.add(uri);}
            @Override public void revokeUriPermission(Uri uri,int flags){revoked.add(uri);}
        };
        LegacyDragFiles.Export image=LegacyDragFiles.publish(context,"private.png","image/png",()->new java.io.ByteArrayInputStream(new byte[]{1}));
        image.grant(captures,new String[]{"com.target"});
        assertEquals(java.util.List.of(image.uri,Uri.parse("content://media/external/images/media/1")),granted);
        LegacyDragFiles.remove(captures,image.uri);assertTrue(revoked.contains(image.readUri));
        granted.clear();
        LegacyDragFiles.Export document=LegacyDragFiles.publish(context,"private.pdf","application/pdf",()->new java.io.ByteArrayInputStream(new byte[]{2}));
        document.grant(captures,new String[]{"com.target"});
        assertEquals(java.util.List.of(document.uri,Uri.parse("content://media/external/file/2")),granted);
        LegacyDragFiles.remove(captures,document.uri);assertTrue(revoked.contains(document.readUri));
    }
    public static final class Media extends ContentProvider {
        final Map<Uri,File> files=new LinkedHashMap<>();final Map<Uri,Integer> types=new LinkedHashMap<>();int inserted,deleted;Uri last;boolean failOutput;String copyThread="";
        @Override public boolean onCreate(){return true;}
        @Override public Uri insert(Uri collection,ContentValues values) {
            last=collection.buildUpon().appendPath(Integer.toString(++inserted)).build();
            String type=values.getAsString("mime_type");types.put(last,type.startsWith("image/")?1:0);
            files.put(last,new File(getContext().getCacheDir(),"public-export-"+inserted));return last;
        }
        @Override public String getType(Uri uri){return "image/png";}
        @Override public Cursor query(Uri uri,String[] projection,String selection,String[] args,String sort) {
            String[] columns=projection==null?new String[]{"_data",OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE}:projection;
            if(!files.containsKey(uri) && uri.getPathSegments().contains("file"))
                uri=Uri.parse("content://media/external/downloads/"+uri.getLastPathSegment());
            MatrixCursor cursor=new MatrixCursor(columns);Object[] row=new Object[columns.length];File file=files.get(uri);
            for(int i=0;i<columns.length;i++)row[i]="_data".equals(columns[i])?file.getPath():"media_type".equals(columns[i])?types.getOrDefault(uri,1):OpenableColumns.DISPLAY_NAME.equals(columns[i])?file.getName():OpenableColumns.SIZE.equals(columns[i])?file.length():null;
            cursor.addRow(row);return cursor;
        }
        @Override public ParcelFileDescriptor openFile(Uri uri,String mode) throws FileNotFoundException {
            copyThread=Thread.currentThread().getName();if(failOutput)throw new FileNotFoundException("test output unavailable");
            return ParcelFileDescriptor.open(files.get(uri),ParcelFileDescriptor.MODE_READ_WRITE|ParcelFileDescriptor.MODE_CREATE|ParcelFileDescriptor.MODE_TRUNCATE);
        }
        @Override public int update(Uri uri,ContentValues values,String selection,String[] args){return 1;}
        @Override public int delete(Uri uri,String selection,String[] args){File file=files.remove(uri);if(file!=null){file.delete();deleted++;}return 1;}
    }
}
