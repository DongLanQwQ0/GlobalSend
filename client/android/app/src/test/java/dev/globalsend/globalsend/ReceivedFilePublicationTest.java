package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.app.Application;
import android.net.Uri;
import android.os.Environment;
import android.os.Process;
import android.os.storage.StorageManager;
import android.provider.DocumentsContract;
import java.io.File;
import java.nio.file.Files;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowMediaScannerConnection;
import org.robolectric.shadows.StorageVolumeBuilder;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34, manifest = Config.NONE)
public class ReceivedFilePublicationTest {
    private Application app;
    private File root, folder;
    @Before public void setup() throws Exception {
        app = RuntimeEnvironment.getApplication();
        root = Environment.getExternalStorageDirectory().getCanonicalFile();
        folder = new File(root, "Download/GlobalSend-publication"); folder.mkdirs();
        var storage = Shadows.shadowOf(app.getSystemService(StorageManager.class));
        storage.resetStorageVolumeList();
        storage.addStorageVolume(new StorageVolumeBuilder("primary", root, "Primary",
                Process.myUserHandle(), Environment.MEDIA_MOUNTED).setIsPrimary(true).build());
    }

    @Test public void finalNamesOfOrdinaryFilesAndImagesAreScannedWithoutCopy() throws Exception {
        for (String name : new String[]{"正文.txt", "报告.pdf", "图片.jpg", "empty.bin"}) {
            File partial = new File(folder, name + ".part"), complete = new File(folder, name);
            byte[] bytes = name.equals("empty.bin") ? new byte[0] : new byte[]{1, 3, 5};
            Files.write(partial.toPath(), bytes);
            Files.move(partial.toPath(), complete.toPath());
            assertTrue(ReceivedFilePublication.publish(app, complete.getPath(), null));
            assertTrue(ShadowMediaScannerConnection.getSavedPaths().contains(complete.getPath()));
            assertFalse(ShadowMediaScannerConnection.getSavedPaths().contains(partial.getPath()));
            assertArrayEquals(bytes, Files.readAllBytes(complete.toPath()));
            assertFalse(partial.exists());
        }
    }

    @Test public void localSafDocumentResolvesToSameSharedFileWithoutAllFilesPermission() throws Exception {
        Uri tree = DocumentsContract.buildTreeDocumentUri("com.android.externalstorage.documents", "primary:Download/GlobalSend-publication");
        Uri doc = DocumentsContract.buildDocumentUriUsingTree(tree, "primary:Download/GlobalSend-publication/报告.pdf");
        assertEquals(new File(folder, "报告.pdf"), ReceivedFilePublication.sharedFile(app, doc.toString()));
    }

    @Test public void privateAndOpaqueProviderFilesAreNotExposedOrCopied() throws Exception {
        File privateFile = new File(app.getFilesDir(), "private.txt");
        Files.write(privateFile.toPath(), new byte[]{8});
        assertFalse(ReceivedFilePublication.publish(app, privateFile.getPath(), null));
        assertFalse(ReceivedFilePublication.publish(app, "content://cloud-provider/document/123", null));
        assertFalse(ReceivedFilePublication.publish(app, folder.getPath(), null));
        assertTrue(ShadowMediaScannerConnection.getSavedPaths().isEmpty());
    }
}
