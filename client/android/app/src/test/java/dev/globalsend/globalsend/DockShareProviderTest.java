package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.content.Context;
import android.content.pm.ProviderInfo;
import android.database.Cursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.File;
import java.nio.file.Files;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowBinder;
import org.robolectric.shadows.ShadowContentResolver;

@RunWith(RobolectricTestRunner.class)
@Config(sdk=34,manifest=Config.NONE)
public class DockShareProviderTest {
    private DockShareProvider published(Context context) {
        DockShareProvider result=new DockShareProvider();ProviderInfo info=new ProviderInfo();
        info.authority=context.getPackageName()+".dock-files";result.attachInfo(context,info);
        ShadowContentResolver.registerProviderInternal(info.authority,result);return result;
    }
    @Test public void documentUriExportsNamedReadOnlyDescriptorAndTracksExternalRead() throws Exception {
        Context context=RuntimeEnvironment.getApplication();
        AndroidDragTest.FixtureProvider source=new AndroidDragTest.FixtureProvider() {
            @Override public String getType(Uri uri){return "image/png";}
        };
        source.directory=new File(context.getFilesDir(),"document-source");assertTrue(source.directory.mkdirs());
        File file=new File(source.directory,"照片 one.png");byte[] data={3,1,4};Files.write(file.toPath(),data);
        ProviderInfo info=new ProviderInfo();info.authority="photo-documents";source.attachInfo(context,info);
        ShadowContentResolver.registerProviderInternal(info.authority,source);
        String original=new Uri.Builder().scheme("content").authority(info.authority).appendPath(file.getName()).build().toString();
        DockShareProvider proxy=published(context);Uri exported=DockShareProvider.registerReadSource(context,original);
        assertNotEquals(Uri.parse(original),exported);assertEquals(file.getName(),exported.getLastPathSegment());
        assertEquals("image/png",proxy.getType(exported));
        try(Cursor cursor=proxy.query(exported,new String[]{OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE},null,null,null)) {
            assertTrue(cursor.moveToFirst());assertEquals(file.getName(),cursor.getString(0));assertEquals(data.length,cursor.getLong(1));
        }
        long started=android.os.SystemClock.uptimeMillis();assertFalse(DockShareProvider.wasReadSince(original,started));
        ShadowBinder.setCallingUid(android.os.Process.myUid());
        try(ParcelFileDescriptor fd=proxy.openFile(exported,"r")) {assertArrayEquals(data,new java.io.FileInputStream(fd.getFileDescriptor()).readAllBytes());}
        assertFalse("source previews are not delivery",DockShareProvider.wasReadSince(original,started));
        int caller=android.os.Process.FIRST_APPLICATION_UID+2345;ShadowBinder.setCallingUid(caller);
        try(ParcelFileDescriptor fd=proxy.openFile(exported,"r")) {assertArrayEquals(data,new java.io.FileInputStream(fd.getFileDescriptor()).readAllBytes());}
        assertEquals(caller,android.os.Binder.getCallingUid());assertTrue(DockShareProvider.wasReadSince(original,started));
        try {proxy.openFile(exported,"w");fail("read only");}catch(java.io.FileNotFoundException expected){}
        assertArrayEquals(data,Files.readAllBytes(file.toPath()));
    }
    @Test public void directoryDocumentKeepsExistingUriAndDoesNotRequireFileMetadata() throws Exception {
        Context context=RuntimeEnvironment.getApplication();
        AndroidDragTest.FixtureProvider source=new AndroidDragTest.FixtureProvider() {
            @Override public String getType(Uri uri){return android.provider.DocumentsContract.Document.MIME_TYPE_DIR;}
            @Override public Cursor query(Uri uri,String[] p,String s,String[] a,String o){throw new AssertionError("directory is not a file");}
        };
        ProviderInfo info=new ProviderInfo();info.authority="directory-source";source.attachInfo(context,info);
        ShadowContentResolver.registerProviderInternal(info.authority,source);
        Uri original=Uri.parse("content://directory-source/folder");
        assertEquals(original,DockShareProvider.registerReadSource(context,original.toString()));
    }
    @Test public void assetOnlyDocumentPreservesOffsetsAndTypedStreamsWithoutCopying() throws Exception {
        Context context=RuntimeEnvironment.getApplication();
        AndroidDragTest.FixtureProvider source=new AndroidDragTest.FixtureProvider() {
            @Override public String getType(Uri uri){return "image/png";}
            @Override public String[] getStreamTypes(Uri uri,String filter){return new String[]{"image/png"};}
            @Override public ParcelFileDescriptor openFile(Uri uri,String mode) throws java.io.FileNotFoundException {throw new java.io.FileNotFoundException("asset-only source");}
            @Override public android.content.res.AssetFileDescriptor openAssetFile(Uri uri,String mode) throws java.io.FileNotFoundException {
                return new android.content.res.AssetFileDescriptor(ParcelFileDescriptor.open(new File(directory,uri.getLastPathSegment()),ParcelFileDescriptor.MODE_READ_ONLY),2,3);
            }
            @Override public android.content.res.AssetFileDescriptor openTypedAssetFile(Uri uri,String type,android.os.Bundle options) throws java.io.FileNotFoundException {return openAssetFile(uri,"r");}
        };
        source.directory=new File(context.getFilesDir(),"asset-source");assertTrue(source.directory.mkdirs());
        File original=new File(source.directory,"slice.png");Files.write(original.toPath(),new byte[]{9,9,3,1,4,8});
        ProviderInfo info=new ProviderInfo();info.authority="asset-source";source.attachInfo(context,info);ShadowContentResolver.registerProviderInternal(info.authority,source);
        DockShareProvider proxy=published(context);Uri exported=DockShareProvider.registerReadSource(context,"content://asset-source/slice.png");
        try(android.content.res.AssetFileDescriptor asset=proxy.openAssetFile(exported,"r")) {
            assertEquals(2,asset.getStartOffset());assertEquals(3,asset.getDeclaredLength());assertArrayEquals(new byte[]{3,1,4},asset.createInputStream().readAllBytes());
        }
        try(android.content.res.AssetFileDescriptor asset=proxy.openTypedAssetFile(exported,"image/png",null)) {
            assertArrayEquals(new byte[]{3,1,4},asset.createInputStream().readAllBytes());
        }
        assertArrayEquals(new String[]{"image/png"},proxy.getStreamTypes(exported,"image/*"));
    }
}
