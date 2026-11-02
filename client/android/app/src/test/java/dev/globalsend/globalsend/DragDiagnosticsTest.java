package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.content.Context;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk=34,manifest=Config.NONE)
public class DragDiagnosticsTest {
    @Test public void explicitMarkerRecordsBoundedOwnEventsOffUiAndRemovalDisablesWrites() throws Exception {
        Context context=RuntimeEnvironment.getApplication();
        DragDiagnostics.initialize(context);DragDiagnostics.idle().get();
        File directory=new File(context.getExternalCacheDir(),DragDiagnostics.DIRECTORY);
        File marker=new File(directory,"enabled"),log=new File(directory,"drag.log");
        marker.delete();log.delete();
        try {
            DragDiagnostics.record("must stay disabled");DragDiagnostics.idle().get();assertFalse(log.exists());
            assertTrue(marker.createNewFile());
            DragDiagnostics.record("begin export source=FrameLayout");DragDiagnostics.idle().get();
            String first=new String(Files.readAllBytes(log.toPath()),StandardCharsets.UTF_8);
            assertTrue(first.contains("begin export source=FrameLayout"));assertTrue(first.contains("diagnostics enabled"));
            assertTrue(first.contains("\"ioThread\":\"GlobalSend-drag-diagnostics\""));
            // Real file IO is serialized behind the test barrier, not a sleep.
            for(int i=0;i<240;i++)DragDiagnostics.record("provider query "+i+" "+new String(new char[500]).replace('\0','x'));
            DragDiagnostics.idle().get();assertTrue(log.length()<=DragDiagnostics.MAX_BYTES);
            assertTrue(new String(Files.readAllBytes(log.toPath()),StandardCharsets.UTF_8).contains("provider query 239"));
            byte[] before=Files.readAllBytes(log.toPath());assertTrue(marker.delete());
            DragDiagnostics.record("must not write after removal");DragDiagnostics.idle().get();
            assertArrayEquals(before,Files.readAllBytes(log.toPath()));
        } finally {marker.delete();log.delete();directory.delete();}
    }
}
