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
import android.provider.MediaStore;
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
import org.robolectric.shadows.ShadowMediaScannerConnection;

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
        assertTrue("Only the compatibility cache is hidden before publication",media.hiddenAtPublish);
        assertFalse("The pending filename must not be remembered as the origin",ReceivedFilePublication.receivedPaths(context).contains(media.pendingPath));
        assertTrue(ReceivedFilePublication.receivedPaths(context).contains(path));
        assertFalse(new File(path).getName().startsWith(".pending-"));
        assertEquals(1,media.inserted);assertFalse(media.copyThread.contains("main"));
        try(Cursor again=externalQuery(uri,null)){assertTrue(again.moveToFirst());assertEquals(path,again.getString(again.getColumnIndexOrThrow("_data")));}
        assertEquals(1,media.inserted);assertTrue(DockShareProvider.wasAccessedSince(original.getPath(),started));
        LegacyDragFiles.remove(context,media.last);
        assertEquals(1,media.deleted);assertFalse(new File(path).exists());assertArrayEquals(bytes,Files.readAllBytes(original.toPath()));
    }
    @Test public void publicOriginalUsesItsExistingPathWithoutCreatingAnotherFile() throws Exception {
        setup();File original=new File(android.os.Environment.getExternalStorageDirectory(),"Download/existing.jpg");
        assertTrue(original.getParentFile().mkdirs() || original.getParentFile().isDirectory());Files.write(original.toPath(),new byte[]{1,2,3});
        media.files.put(Uri.parse("content://media/external/images/media/71"),original);
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
        assertEquals(java.util.List.of(image.uri,Uri.parse("content://media/external/file/1")),granted);
        LegacyDragFiles.remove(captures,image.uri);assertTrue(revoked.contains(image.readUri));
        granted.clear();
        LegacyDragFiles.Export document=LegacyDragFiles.publish(context,"private.pdf","application/pdf",()->new java.io.ByteArrayInputStream(new byte[]{2}));
        document.grant(captures,new String[]{"com.target"});
        assertEquals(java.util.List.of(document.uri,Uri.parse("content://media/external/file/2")),granted);
        LegacyDragFiles.remove(captures,document.uri);assertTrue(revoked.contains(document.readUri));
    }
    @Test public void finalPathAndGrantFollowPublishRenameAndHiddenMediaClassification() throws Exception {
        setup();byte[] original={8,9,7};
        LegacyDragFiles.Export image=LegacyDragFiles.publish(context,"drag.png","image/png",()->new java.io.ByteArrayInputStream(original));
        assertTrue(media.hiddenAtPublish);
        assertFalse(new File(media.pendingPath).exists());
        assertTrue(new File(image.path).isFile());assertArrayEquals(original,Files.readAllBytes(new File(image.path).toPath()));
        assertEquals(MediaStore.Files.FileColumns.MEDIA_TYPE_NONE,(int)media.types.get(image.uri));
        assertEquals(Uri.parse("content://media/external/file/1"),image.readUri);
        assertTrue(new File(new File(image.path).getParentFile(),".nomedia").isFile());
        LegacyDragFiles.remove(context,image.uri);assertFalse(new File(image.path).exists());
    }
    @Test public void mediaProviderFailureToPublishHiddenCopyDoesNotReturnStalePathOrConsumeSource() throws Exception {
        setup();media.keepImageClassification=true;File original=new File(context.getFilesDir(),"still-visible.png");
        Files.write(original.toPath(),new byte[]{5,1});Uri uri=DockShareProvider.registerReadSource(context,original.getPath());
        long started=android.os.SystemClock.uptimeMillis();assertNull(externalQuery(uri,null));
        assertFalse(DockShareProvider.wasAccessedSince(original.getPath(),started));assertTrue(original.isFile());
        assertEquals(1,media.deleted);assertTrue(context.getSharedPreferences("drag-path-exports",0).getAll().isEmpty());
    }
    @Test public void restoredJournalRescansOnlyItsExactCompatibilityCopyAndKeepsOrdinaryReceiptsVisible() throws Exception {
        setup();File downloads=android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOWNLOADS);
        File copy=new File(downloads,"GlobalSend/Drag-cache/restored.png"),receipt=new File(downloads,"GlobalSend/receipt.png");
        assertTrue(copy.getParentFile().mkdirs() || copy.getParentFile().isDirectory());
        Files.write(copy.toPath(),new byte[]{2});Files.write(receipt.toPath(),new byte[]{3});
        Uri owned=Uri.parse("content://media/external/downloads/501"),original=Uri.parse("content://media/external/images/media/502");
        media.files.put(owned,copy);media.files.put(original,receipt);
        context.getSharedPreferences("drag-path-exports",0).edit().putLong(owned.toString(),System.currentTimeMillis()+600000).commit();
        LegacyDragFiles.hideRestoredExport(context,owned);
        LegacyDragFiles.hideRestoredExport(context,original);
        assertEquals(java.util.Set.of(copy.getCanonicalPath()),ShadowMediaScannerConnection.getSavedPaths());
        assertTrue(new File(copy.getParentFile(),".nomedia").isFile());
        assertFalse(new File(receipt.getParentFile(),".nomedia").exists());
        assertArrayEquals(new byte[]{3},Files.readAllBytes(receipt.toPath()));assertTrue(copy.isFile());assertEquals(0,media.deleted);
    }
    @Test public void borrowedMediaGrantsExpireWithoutDeletingOrCopyingTheOriginal() throws Exception {
        setup();File original=new File(android.os.Environment.getExternalStorageDirectory(),"Download/borrowed.png");
        assertTrue(original.getParentFile().mkdirs() || original.getParentFile().isDirectory());Files.write(original.toPath(),new byte[]{1,2});
        Uri mediaUri=Uri.parse("content://media/external/images/media/91");media.files.put(mediaUri,original);
        LegacyDragFiles.Export borrowed=LegacyDragFiles.existing(context,original.getCanonicalPath(),null);
        assertNotNull(borrowed);assertFalse(borrowed.owned);assertEquals(original.getCanonicalPath(),borrowed.path);
        assertEquals(0,media.inserted);
        java.util.List<Uri> revoked=new java.util.ArrayList<>();
        Context captures=new android.content.ContextWrapper(context) {
            @Override public void grantUriPermission(String target,Uri uri,int flags){}
            @Override public void revokeUriPermission(Uri uri,int flags){revoked.add(uri);}
        };
        borrowed.grant(captures,new String[]{"com.target"});
        var journal=context.getSharedPreferences("drag-path-read-grants",0);
        assertTrue(journal.contains(borrowed.uri.toString()));assertTrue(journal.contains(borrowed.readUri.toString()));
        for(Uri alias:java.util.List.of(borrowed.uri,borrowed.readUri)) {
            journal.edit().putLong(alias.toString(),0).commit();LegacyDragFiles.expireReadGrant(captures,alias);
        }
        assertEquals(java.util.List.of(borrowed.uri,borrowed.readUri),revoked);
        assertEquals(0,media.deleted);assertTrue(original.exists());
    }
    public static final class Media extends ContentProvider {
        final Map<Uri,File> files=new LinkedHashMap<>();final Map<Uri,Integer> types=new LinkedHashMap<>();int inserted,deleted;Uri last;
        boolean failOutput,hiddenAtPublish,keepImageClassification;String copyThread="",pendingPath="";
        @Override public boolean onCreate(){return true;}
        @Override public Uri insert(Uri collection,ContentValues values) {
            last=collection.buildUpon().appendPath(Integer.toString(++inserted)).build();
            String type=values.getAsString("mime_type");types.put(last,type.startsWith("image/")?1:0);
            File folder=new File(getContext().getCacheDir(),"public-export-"+inserted);folder.mkdirs();
            File pending=new File(folder,".pending-12345-"+values.getAsString(MediaStore.MediaColumns.DISPLAY_NAME));
            pendingPath=pending.getPath();files.put(last,pending);return last;
        }
        @Override public String getType(Uri uri){return "image/png";}
        @Override public Cursor query(Uri uri,String[] projection,String selection,String[] args,String sort) {
            String[] columns=projection==null?new String[]{"_data",OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE}:projection;
            MatrixCursor cursor=new MatrixCursor(columns);
            if(selection!=null && args!=null) {
                uri=files.entrySet().stream().filter(entry->entry.getValue().getPath().equals(args[0])).map(Map.Entry::getKey).findFirst().orElse(null);
            }else if(!files.containsKey(uri)) {
                String id=uri.getLastPathSegment();uri=files.keySet().stream().filter(key->key.getLastPathSegment().equals(id)).findFirst().orElse(null);
            }
            File file=files.get(uri);if(file==null)return cursor;Object[] row=new Object[columns.length];
            for(int i=0;i<columns.length;i++)row[i]="_id".equals(columns[i])?Long.valueOf(uri.getLastPathSegment()):"_data".equals(columns[i])?file.getPath():"media_type".equals(columns[i])?types.getOrDefault(uri,1):OpenableColumns.DISPLAY_NAME.equals(columns[i])?file.getName():OpenableColumns.SIZE.equals(columns[i])?file.length():null;
            cursor.addRow(row);return cursor;
        }
        @Override public ParcelFileDescriptor openFile(Uri uri,String mode) throws FileNotFoundException {
            copyThread=Thread.currentThread().getName();if(failOutput)throw new FileNotFoundException("test output unavailable");
            return ParcelFileDescriptor.open(files.get(uri),ParcelFileDescriptor.MODE_READ_WRITE|ParcelFileDescriptor.MODE_CREATE|ParcelFileDescriptor.MODE_TRUNCATE);
        }
        @Override public int update(Uri uri,ContentValues values,String selection,String[] args){
            if(Integer.valueOf(0).equals(values.getAsInteger(MediaStore.MediaColumns.IS_PENDING))) {
                File pending=files.get(uri);hiddenAtPublish=new File(pending.getParentFile(),".nomedia").isFile();
                File ready=new File(pending.getParentFile(),pending.getName().substring(".pending-12345-".length()));
                if(!pending.renameTo(ready))throw new IllegalStateException("Test publish rename failed");
                files.put(uri,ready);if(hiddenAtPublish && !keepImageClassification)types.put(uri,MediaStore.Files.FileColumns.MEDIA_TYPE_NONE);
            }
            return 1;
        }
        @Override public int delete(Uri uri,String selection,String[] args){File file=files.remove(uri);if(file!=null){file.delete();deleted++;}return 1;}
    }
}
