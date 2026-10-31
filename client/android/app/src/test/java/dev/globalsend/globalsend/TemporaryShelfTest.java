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
    @Test public void mediaSuggestionsSpendOnlyVisibleTimeAndConfirmedContentRemains() {
        TemporaryShelf shelf=new TemporaryShelf(RuntimeEnvironment.getApplication(),() -> {});
        shelf.suggest(List.of(new RecentMediaSuggestions.Media("content://fixture/one","one.jpg",1),
            new RecentMediaSuggestions.Media("content://fixture/two","two.jpg",2)));
        shelf.add(List.of("content://fixture/two"),List.of("manual text"),Map.of());
        String id=shelf.items.values().stream().filter(item -> "content://fixture/one".equals(item.localPath)).findFirst().get().id;
        advance(60_000);assertEquals("Undisplayed suggestions never start a timer",3,shelf.items.size());
        shelf.setVisibleSuggestions(java.util.Set.of(id));
        advance(4000);shelf.setVisibleSuggestions(java.util.Set.of());
        advance(60_000);assertEquals("Collapsed, offscreen and operating time is excluded",3,shelf.items.size());
        shelf.setVisibleSuggestions(java.util.Set.of(id));
        advance(3999);assertEquals(3,shelf.items.size());
        advance(1);assertEquals(2,shelf.items.size());
        assertTrue(shelf.suggestedPaths().isEmpty());
        assertTrue(shelf.items.values().stream().anyMatch(item -> "content://fixture/two".equals(item.localPath)));
        assertTrue(shelf.items.values().stream().anyMatch(item -> "manual text".equals(item.text)));
    }
    @Test public void eachSuggestionHasItsOwnVisibleBudgetAndPromotionCancelsExpiry() {
        TemporaryShelf shelf=new TemporaryShelf(RuntimeEnvironment.getApplication(),() -> {});
        shelf.suggest(List.of(new RecentMediaSuggestions.Media("content://fixture/first","first.jpg",1),
            new RecentMediaSuggestions.Media("content://fixture/later","later.jpg",2)));
        String first=shelf.items.values().stream().filter(item -> "first.jpg".equals(item.fileName)).findFirst().get().id;
        String later=shelf.items.values().stream().filter(item -> "later.jpg".equals(item.fileName)).findFirst().get().id;
        shelf.setVisibleSuggestions(java.util.Set.of(first));advance(7999);
        shelf.add(List.of("content://fixture/first"),List.of(),Map.of());advance(20_000);
        assertEquals(2,shelf.items.size());assertFalse(shelf.isSuggested(first));
        shelf.setVisibleSuggestions(java.util.Set.of(later));advance(7999);assertTrue(shelf.items.containsKey(later));
        advance(1);assertFalse(shelf.items.containsKey(later));assertTrue(shelf.items.containsKey(first));
    }
    @Test public void restoredSuggestionsKeepRemainingVisibleBudgetNotWallClockAge() throws Exception {
        Context context=RuntimeEnvironment.getApplication();
        org.json.JSONArray records=new org.json.JSONArray().put(new org.json.JSONObject()
            .put("id","saved").put("path","content://fixture/saved").put("name","saved.jpg")
            .put("suggested",true).put("suggestedAt",1).put("suggestionRemainingMs",3000))
            .put(new org.json.JSONObject().put("id","legacy").put("path","content://fixture/legacy")
                .put("name","legacy.jpg").put("suggested",true).put("suggestedAt",1));
        Files.write(new File(context.getFilesDir(),"temporary-shelf.json").toPath(),records.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
        TemporaryShelf shelf=new TemporaryShelf(context,() -> {});
        java.util.concurrent.ExecutorService io=org.robolectric.util.ReflectionHelpers.getField(shelf,"io");
        io.submit(() -> {}).get(5,java.util.concurrent.TimeUnit.SECONDS);advance(60_000);
        assertEquals(2,shelf.items.size());
        shelf.setVisibleSuggestions(java.util.Set.of("saved","legacy"));advance(2999);assertEquals(2,shelf.items.size());
        advance(1);assertFalse(shelf.items.containsKey("saved"));assertTrue(shelf.items.containsKey("legacy"));
        advance(4999);assertTrue(shelf.items.containsKey("legacy"));advance(1);assertTrue(shelf.items.isEmpty());
    }
    private void advance(long millis) { Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(millis)); }
    @Test public void missingSuggestionsLeaveValidSuggestionsAndExplicitlyStagedReferencesAlone() {
        TemporaryShelf shelf=new TemporaryShelf(RuntimeEnvironment.getApplication(),() -> {});
        String gone="content://media/external/images/media/201",promoted="content://media/external/images/media/202",valid="content://media/external/video/media/203";
        shelf.suggest(List.of(new RecentMediaSuggestions.Media(gone,"gone.jpg",1),
            new RecentMediaSuggestions.Media(promoted,"promoted.jpg",2),new RecentMediaSuggestions.Media(valid,"valid.mp4",3)));
        assertEquals(3,shelf.suggestedPaths().size());
        ReceiveNotifications.Receipt pending=shelf.items.values().stream().filter(item -> item.localPath.equals(gone)).findFirst().get();
        shelf.exported(List.of(pending),true);
        // Promotion after an asynchronous scan's snapshot must win.
        shelf.add(List.of(promoted),List.of("manual text"),Map.of());
        shelf.removeMissingSuggestions(java.util.Set.of(gone,promoted));
        assertEquals(3,shelf.items.size());assertFalse(shelf.items.containsKey(pending.id));
        assertEquals(List.of(valid),shelf.suggestedPaths());assertEquals(0,shelf.removalSeconds());
        assertTrue(shelf.items.values().stream().anyMatch(item -> item.localPath.equals(promoted)));
        assertTrue(shelf.items.values().stream().anyMatch(item -> "manual text".equals(item.text)));
    }
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
