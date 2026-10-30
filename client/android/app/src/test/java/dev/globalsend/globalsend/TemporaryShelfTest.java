package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.content.Context;
import android.os.Looper;
import java.io.File;
import java.nio.file.Files;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk=34, manifest=Config.NONE)
public class TemporaryShelfTest {
    private void advance(long millis) { Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(millis)); }
    @Test public void mediaSuggestionBecomesRegularWhenExplicitlyStagedAndKeepsExportGrace() {
        TemporaryShelf shelf=new TemporaryShelf(RuntimeEnvironment.getApplication(),() -> {});
        String uri="content://media/external/video/media/77";
        shelf.suggest(List.of(new RecentMediaSuggestions.Media(uri,"clip.mp4",1)));
        ReceiveNotifications.Receipt item=shelf.items.values().iterator().next();assertTrue(shelf.isSuggested(item.id));
        shelf.add(List.of(uri),List.of(),Map.of());
        assertEquals(1,shelf.items.size());assertFalse(shelf.isSuggested(item.id));
        shelf.exported(List.of(item),true);advance(2999);assertEquals(1,shelf.items.size());
        assertTrue(shelf.cancelRemoval());advance(100);assertEquals(1,shelf.items.size());
        shelf.exported(List.of(item),true);advance(3000);assertTrue(shelf.items.isEmpty());
    }
    @Test public void nativeAcceptanceDoesNotRemoveAFileThatTheTargetNeverRead() {
        TemporaryShelf shelf=new TemporaryShelf(RuntimeEnvironment.getApplication(),() -> {});
        shelf.add(List.of("/unread.png","/read.png"),List.of("text"),Map.of());
        List<ReceiveNotifications.Receipt> batch=new ArrayList<>(shelf.items.values());
        java.util.Set<String> read=new java.util.HashSet<>();
        shelf.exported(batch,true,item -> item.text!=null || read.contains(item.localPath));
        advance(2999);assertEquals(3,shelf.items.size());read.add("/read.png");advance(1);
        assertEquals(1,shelf.items.size());assertEquals("/unread.png",shelf.items.values().iterator().next().localPath);
        assertEquals(0,shelf.removalSeconds());assertFalse(shelf.pendingRemoval(shelf.items.keySet().iterator().next()));
    }
    @Test public void multipleBatchesStayDistinctFromReceiptsAndOnlyAcceptedExportsExpire() throws Exception {
        Context context = RuntimeEnvironment.getApplication();
        File original = new File(context.getFilesDir(), "original.jpg");
        Files.write(original.toPath(), "original bytes".getBytes(java.nio.charset.StandardCharsets.UTF_8));
        TemporaryShelf shelf = new TemporaryShelf(context, () -> {});
        shelf.add(List.of(original.getPath()), List.of("第一批"), Map.of());
        shelf.add(List.of(), List.of("第二批"), Map.of());
        assertEquals(3, shelf.items.size());
        List<ReceiveNotifications.Receipt> first = new ArrayList<>(shelf.items.values());
        shelf.exported(first, false); advance(4000); assertEquals(3, shelf.items.size());
        shelf.exported(first.subList(0,1), true);
        assertEquals(3, shelf.removalSeconds()); advance(2999); assertEquals(3, shelf.items.size());
        advance(1); assertEquals(2, shelf.items.size());
        shelf.exported(new ArrayList<>(shelf.items.values()), true);
        advance(1000); assertTrue(shelf.cancelRemoval()); advance(4000);
        assertEquals(2, shelf.items.size());
        shelf.exported(new ArrayList<>(shelf.items.values()), true); advance(3000);
        assertTrue(shelf.items.isEmpty());
        assertEquals("original bytes", new String(Files.readAllBytes(original.toPath()), java.nio.charset.StandardCharsets.UTF_8));
    }
}
