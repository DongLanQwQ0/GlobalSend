package dev.globalsend.globalsend;

import android.Manifest;
import android.content.ContentUris;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.database.ContentObserver;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;
import java.io.File;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.Consumer;
import org.json.JSONObject;

/** Metadata-only media discovery for the persistent dock. Never opens a permission dialog. */
final class RecentMediaSuggestions {
    static final class Media {
        final String uri,name;
        final long added;
        Media(String uri,String name,long added) {this.uri=uri;this.name=name;this.added=added;}
    }
    private static final ExecutorService io=Executors.newSingleThreadExecutor();
    private final Context context;
    private final Handler main=new Handler(Looper.getMainLooper());
    private final SharedPreferences state;
    private final Consumer<List<Media>> found;
    private final Runnable disabled;
    private final Runnable scan=this::scan;
    private boolean started,busy,again;
    private int generation;
    private final ContentObserver changes=new ContentObserver(main) {
        @Override public void onChange(boolean selfChange) {refresh();}
    };
    RecentMediaSuggestions(Context context,Consumer<List<Media>> found,Runnable disabled) {
        this.context=context;this.found=found;this.disabled=disabled;
        state=context.getSharedPreferences("dock-media-suggestions",Context.MODE_PRIVATE);
    }
    void start() {
        if(started)return;
        started=true;generation++;
        context.getContentResolver().registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,true,changes);
        context.getContentResolver().registerContentObserver(MediaStore.Video.Media.EXTERNAL_CONTENT_URI,true,changes);
        refresh();
    }
    void stop() {
        if(!started)return;
        started=false;generation++;main.removeCallbacks(scan);
        context.getContentResolver().unregisterContentObserver(changes);
    }
    void refresh() {
        if(!started)return;
        main.removeCallbacks(scan);main.postDelayed(scan,350);
    }
    private void scan() {
        if(!started)return;
        if(busy) {again=true;return;}
        busy=true;
        final int request=generation;
        io.execute(() -> {
            List<Media> media=new ArrayList<>();
            Set<String> seen=new LinkedHashSet<>(state.getStringSet("seen",Set.of()));
            boolean enabled=true;
            try {
                // Same switch and initial lookback as the main application's media suggestions.
                long now=System.currentTimeMillis(),since=state.getLong("since",now-600_000);
                File settings=new File(context.getFilesDir(),"recent-photo-suggestions.json");
                Set<String> handled=new HashSet<>();
                if(settings.isFile()) {
                    JSONObject value=new JSONObject(new String(Files.readAllBytes(settings.toPath()),java.nio.charset.StandardCharsets.UTF_8));
                    enabled=value.optBoolean("enabled",true);
                    org.json.JSONArray ids=value.optJSONArray("handled");
                    if(ids!=null)for(int i=0;i<ids.length();i++)handled.add(ids.getString(i));
                }
                if(enabled) {
                    since=Math.max(since,now-86_400_000);
                    collect(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,Manifest.permission.READ_MEDIA_IMAGES,since,seen,handled,media);
                    collect(MediaStore.Video.Media.EXTERNAL_CONTENT_URI,Manifest.permission.READ_MEDIA_VIDEO,since,seen,handled,media);
                    media.sort(Comparator.comparingLong((Media m)->m.added).reversed());
                }
                final boolean active=enabled;
                final long initialSince=since;
                main.post(() -> {
                    busy=false;
                    if(started && generation==request) {
                        if(!active)disabled.run();
                        else if(!media.isEmpty()) {
                            found.accept(media);
                            for(Media item:media)seen.add(item.uri);
                            while(seen.size()>512)seen.remove(seen.iterator().next());
                            state.edit().putLong("since",initialSince).putStringSet("seen",seen).apply();
                        }
                    }
                    if(again) {again=false;refresh();}
                });
            } catch(java.io.IOException | org.json.JSONException | RuntimeException unavailable) {
                android.util.Log.w("GlobalSend","Cannot check recent media",unavailable);
                main.post(() -> {busy=false;if(again) {again=false;refresh();}});
            }
        });
    }
    private void collect(Uri collection,String permission,long since,Set<String> seen,Set<String> handled,List<Media> result) {
        boolean granted=context.checkSelfPermission(Build.VERSION.SDK_INT>=33?permission:Manifest.permission.READ_EXTERNAL_STORAGE)==PackageManager.PERMISSION_GRANTED;
        if(Build.VERSION.SDK_INT>=34)granted|=context.checkSelfPermission(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)==PackageManager.PERMISSION_GRANTED;
        if(!granted)return;
        String selection=MediaStore.MediaColumns.DATE_ADDED+">=?";
        if(Build.VERSION.SDK_INT>=29)selection+=" AND "+MediaStore.MediaColumns.IS_PENDING+"=0";
        try(Cursor cursor=context.getContentResolver().query(collection,
                new String[]{MediaStore.MediaColumns._ID,MediaStore.MediaColumns.DISPLAY_NAME,MediaStore.MediaColumns.DATE_ADDED},
                selection,new String[]{Long.toString(since/1000)},MediaStore.MediaColumns.DATE_ADDED+" DESC")) {
            if(cursor==null)return;
            int visited=0;
            while(visited++<24 && cursor.moveToNext()) {
                String id=cursor.getString(0),uri=ContentUris.withAppendedId(collection,Long.parseLong(id)).toString();
                if(!seen.contains(uri) && !handled.contains(id)) {
                    String name=cursor.getString(1);
                    if(MediaFileName.needsSuffix(name))name=MediaFileName.withType(name,context.getContentResolver().getType(Uri.parse(uri)));
                    result.add(new Media(uri,name,cursor.getLong(2)));
                }
            }
        }
    }
}
