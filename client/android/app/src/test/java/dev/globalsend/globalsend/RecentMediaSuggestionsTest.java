package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.Manifest;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.Looper;
import java.nio.file.Files;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BooleanSupplier;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowContentResolver;

@RunWith(RobolectricTestRunner.class) @Config(sdk=34,manifest=Config.NONE)
public class RecentMediaSuggestionsTest {
    static class Gallery extends ContentProvider {
        final AtomicInteger reads=new AtomicInteger();
        boolean extra;
        public boolean onCreate() {return true;}
        public Cursor query(Uri uri,String[] columns,String selection,String[] args,String sort) {
            assertTrue(selection.contains("date_added>=?"));assertTrue(selection.contains("is_pending=0"));
            assertEquals("date_added DESC",sort);reads.incrementAndGet();
            MatrixCursor rows=new MatrixCursor(columns);
            long seconds=System.currentTimeMillis()/1000;
            if(uri.toString().contains("images")) {
                rows.addRow(new Object[]{101,"camera.jpg",seconds});
                if(extra)rows.addRow(new Object[]{103,"new.jpg",seconds+1});
            } else rows.addRow(new Object[]{102,"camera.mp4",seconds});
            return rows;
        }
        public String getType(Uri uri) {return "image/jpeg";}
        public Uri insert(Uri uri,ContentValues values) {return null;}
        public int update(Uri uri,ContentValues values,String where,String[] args) {return 0;}
        public int delete(Uri uri,String where,String[] args) {return 0;}
    }
    Context context;Gallery gallery;RecentMediaSuggestions feed;
    final List<RecentMediaSuggestions.Media> suggested=new ArrayList<>();
    final AtomicInteger batches=new AtomicInteger(),disabled=new AtomicInteger();
    @Before public void setup() throws Exception {
        context=RuntimeEnvironment.getApplication();gallery=new Gallery();gallery.attachInfo(context,null);
        ShadowContentResolver.registerProviderInternal("media",gallery);
        Shadows.shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.READ_MEDIA_IMAGES,Manifest.permission.READ_MEDIA_VIDEO);
        Files.deleteIfExists(new java.io.File(context.getFilesDir(),"recent-photo-suggestions.json").toPath());
        context.getSharedPreferences("dock-media-suggestions",0).edit().clear().commit();
        feed=create();
    }
    RecentMediaSuggestions create() {return new RecentMediaSuggestions(context,items -> {batches.incrementAndGet();suggested.addAll(items);},disabled::incrementAndGet);}
    @After public void cleanup() {feed.stop();}
    void until(BooleanSupplier condition) throws Exception {
        for(int i=0;i<200;i++) {
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(30));
            if(condition.getAsBoolean())return;Thread.sleep(10);
        }
        fail("Media observer did not finish");
    }
    @Test public void imageAndVideoAreSuggestedOnceAndOnlyNewRowsAppearAfterRestart() throws Exception {
        feed.start();until(() -> batches.get()==1);assertEquals(2,suggested.size());
        assertTrue(suggested.stream().anyMatch(m -> m.name.endsWith(".mp4")));
        feed.refresh();until(() -> gallery.reads.get()>=4);assertEquals(1,batches.get());
        feed.stop();feed=create();gallery.extra=true;feed.start();until(() -> batches.get()==2);
        assertEquals(3,suggested.size());assertEquals("new.jpg",suggested.get(2).name);
    }
    @Test public void existingSwitchDisablesDockSuggestionsAndObserverStopsWithWindow() throws Exception {
        Files.write(new java.io.File(context.getFilesDir(),"recent-photo-suggestions.json").toPath(),"{\"enabled\":false}".getBytes(java.nio.charset.StandardCharsets.UTF_8));
        feed.start();until(() -> disabled.get()==1);assertEquals(0,gallery.reads.get());
        feed.stop();feed.refresh();Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(1));
        assertEquals(1,disabled.get());assertEquals(0,batches.get());
    }
    @Test public void previouslyHandledMainPageAssetsAreNotSuggestedAgain() throws Exception {
        Files.write(new java.io.File(context.getFilesDir(),"recent-photo-suggestions.json").toPath(),"{\"enabled\":true,\"handled\":[\"101\"]}".getBytes(java.nio.charset.StandardCharsets.UTF_8));
        feed.start();until(() -> batches.get()==1);
        assertEquals(1,suggested.size());assertEquals("camera.mp4",suggested.get(0).name);
    }
}
