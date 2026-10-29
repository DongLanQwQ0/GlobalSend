package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.app.Activity;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Intent;
import android.content.pm.ProviderInfo;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowContentResolver;

@RunWith(RobolectricTestRunner.class)
@Config(sdk=34, manifest=Config.NONE)
public class AndroidFileOpenerTest {
    private final Uri uri=Uri.parse("content://open-fixture/document/opaque-id");
    private Activity source(String name, String type) {
        Activity activity=Robolectric.buildActivity(Activity.class).setup().get();
        ContentProvider provider=new ContentProvider() {
            public boolean onCreate(){return true;}
            public String getType(Uri uri){return type;}
            public Cursor query(Uri uri,String[] projection,String s,String[] a,String sort){
                if(name==null)throw new UnsupportedOperationException("Stream only");
                MatrixCursor result=new MatrixCursor(new String[]{OpenableColumns.DISPLAY_NAME});
                result.addRow(new Object[]{name});return result;
            }
            public Uri insert(Uri uri,ContentValues v){throw new UnsupportedOperationException();}
            public int delete(Uri uri,String s,String[] a){throw new UnsupportedOperationException();}
            public int update(Uri uri,ContentValues v,String s,String[] a){throw new UnsupportedOperationException();}
        };
        ProviderInfo info=new ProviderInfo();info.authority="open-fixture";provider.attachInfo(activity,info);
        ShadowContentResolver.registerProviderInternal(info.authority,provider);return activity;
    }
    @Test public void opaqueDocumentWithApkNameOpensInstallerWithReadGrant() {
        Activity activity=source("安装包.APK","application/octet-stream");
        AndroidFileOpener.open(activity,uri);
        Intent intent=Shadows.shadowOf(activity).getNextStartedActivity();
        assertEquals(Intent.ACTION_VIEW,intent.getAction());assertEquals(AndroidFileOpener.APK,intent.getType());
        assertEquals(uri,intent.getData());assertEquals(uri,intent.getClipData().getItemAt(0).getUri());
        assertTrue((intent.getFlags()&Intent.FLAG_GRANT_READ_URI_PERMISSION)!=0);
        assertTrue((intent.getFlags()&Intent.FLAG_ACTIVITY_NEW_TASK)!=0);
    }
    @Test public void zipMimeForApkDoesNotSendItToArchiveViewer() {
        Activity activity=source("app.apk","application/zip");
        assertEquals(AndroidFileOpener.APK,AndroidFileOpener.viewIntent(activity,uri).getType());
    }
    @Test public void normalDocumentKeepsItsMimeAndActivityTask() {
        Activity activity=source("报告.pdf","application/pdf");
        Intent intent=AndroidFileOpener.viewIntent(activity,uri);
        assertEquals("application/pdf",intent.getType());assertEquals(uri,intent.getData());
        assertEquals(0,intent.getFlags()&Intent.FLAG_ACTIVITY_NEW_TASK);
    }
    @Test public void overlayContextCanLaunchInstallerAndExistingTypedApkStaysTyped() {
        Activity activity=source("opaque",AndroidFileOpener.APK);
        Intent intent=AndroidFileOpener.viewIntent(activity.getApplicationContext(),uri);
        assertEquals(AndroidFileOpener.APK,intent.getType());
        assertTrue((intent.getFlags()&Intent.FLAG_ACTIVITY_NEW_TASK)!=0);
    }
    @Test public void streamOnlyGenericProviderKeepsExistingOpenBehavior() {
        Activity activity=source(null,"application/octet-stream");
        Intent intent=AndroidFileOpener.viewIntent(activity,uri);
        assertEquals("application/octet-stream",intent.getType());assertEquals(uri,intent.getData());
    }
    @Test public void directoryWithApkSuffixStillOpensAsDirectory() {
        String type=android.provider.DocumentsContract.Document.MIME_TYPE_DIR;
        Activity activity=source("bundle.apk",type);
        assertEquals(type,AndroidFileOpener.viewIntent(activity,uri).getType());
    }
}
