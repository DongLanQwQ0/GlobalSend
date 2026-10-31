package dev.globalsend.globalsend;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.json.JSONArray;
import org.json.JSONObject;

/** Installation-local references, deliberately separate from received messages. */
final class TemporaryShelf {
    private static final long SUGGESTION_DURATION_MS=30_000;
    final LinkedHashMap<String, ReceiveNotifications.Receipt> items = new LinkedHashMap<>();
    private final Map<String,Long> suggested = new LinkedHashMap<>();
    private final Map<String,Long> suggestionRemaining = new LinkedHashMap<>();
    private final java.util.Set<String> visibleSuggestions = new java.util.HashSet<>();
    private final Map<String,java.util.Set<String>> suggestionSurfaces = new LinkedHashMap<>();
    private final java.util.Set<String> suggestionInteractions=new java.util.HashSet<>();
    private long suggestionClock;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final File file;
    private final Runnable changed;
    private final Map<String, ReceiveNotifications.Receipt> pendingRemoval = new LinkedHashMap<>();
    private final Map<String,java.util.function.Predicate<ReceiveNotifications.Receipt>> pendingConsumed=new LinkedHashMap<>();
    private long removalDeadline;
    private boolean loaded;

    TemporaryShelf(Context context, Runnable changed) {
        this.file = new File(context.getFilesDir(), "temporary-shelf.json");
        this.changed = changed;
        io.execute(() -> {
            List<ReceiveNotifications.Receipt> restored = new ArrayList<>();
            Map<String,Long> restoredSuggested=new LinkedHashMap<>();
            Map<String,Long> restoredRemaining=new LinkedHashMap<>();
            try {
                if (file.isFile()) {
                    JSONArray records = new JSONArray(new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8));
                    for (int i = 0; i < records.length(); i++) {
                        JSONObject record = records.getJSONObject(i);
                        String path = record.optString("path");
                        // External originals may have been removed while the app was stopped.
                        if (!path.isEmpty() && !path.startsWith("content://") && !new File(path).exists()) continue;
                        long offeredAt=record.optLong("suggestedAt",file.lastModified());
                        long remaining=record.optLong("suggestionRemainingMs",SUGGESTION_DURATION_MS);
                        // Version 81 stored an eight-second budget without its duration.
                        long duration=record.optLong("suggestionDurationMs",record.has("suggestionRemainingMs")?8000:SUGGESTION_DURATION_MS);
                        remaining+=SUGGESTION_DURATION_MS-duration;
                        if(record.optBoolean("suggested") && remaining<=0)continue;
                        restored.add(new ReceiveNotifications.Receipt(record.getString("id"), "1", "暂存",
                            record.has("text") ? record.getString("text") : null, record.optString("name"), path, 0));
                        if(record.optBoolean("suggested")) {
                            restoredSuggested.put(record.getString("id"),offeredAt);
                            restoredRemaining.put(record.getString("id"),remaining);
                        }
                    }
                }
            } catch (java.io.IOException | org.json.JSONException unavailable) {
                android.util.Log.w("GlobalSend", "Cannot restore temporary shelf", unavailable);
            }
            main.post(() -> {
                for (ReceiveNotifications.Receipt receipt : restored)
                    if (!contains(receipt.localPath, receipt.text)) {
                        items.put(receipt.id, receipt);
                        if(restoredSuggested.containsKey(receipt.id)) {
                            long offeredAt=restoredSuggested.get(receipt.id);
                            suggested.put(receipt.id,offeredAt);
                            suggestionRemaining.put(receipt.id,restoredRemaining.get(receipt.id));
                        }
                    }
                loaded = true;
                save(); changed.run();
            });
        });
    }

    boolean contains(String path, String text) {
        for (ReceiveNotifications.Receipt item : items.values())
            if (item.localPath.equals(path) && java.util.Objects.equals(item.text, text)) return true;
        return false;
    }

    void add(List<String> paths, List<String> texts, Map<String, String> names) {
        cancelRemoval();
        for(ReceiveNotifications.Receipt item:items.values())
            if(paths.contains(item.localPath))forgetSuggestion(item.id);
        List<ReceiveNotifications.Receipt> added = new ArrayList<>();
        java.util.Set<String> batchPaths = new java.util.HashSet<>(), batchTexts = new java.util.HashSet<>();
        for (String path : paths) if (batchPaths.add(path) && !contains(path, null)) {
            String name = names.getOrDefault(path, new File(path).getName());
            added.add(new ReceiveNotifications.Receipt("shelf:" + UUID.randomUUID(), "1", "暂存", null, name, path, 0));
        }
        for (String text : texts) if (batchTexts.add(text) && !contains("", text))
            added.add(new ReceiveNotifications.Receipt("shelf:" + UUID.randomUUID(), "1", "暂存", text, "", "", 0));
        LinkedHashMap<String, ReceiveNotifications.Receipt> next = new LinkedHashMap<>();
        for (ReceiveNotifications.Receipt item : added) next.put(item.id, item);
        next.putAll(items); items.clear(); items.putAll(next);
        save(); changed.run();
    }

    boolean isSuggested(String id) {return suggested.containsKey(id);}
    long suggestedAt(String id) {return suggested.getOrDefault(id,0L);}
    List<String> suggestedPaths() {
        List<String> paths=new ArrayList<>();
        for(ReceiveNotifications.Receipt item:items.values())if(suggested.containsKey(item.id))paths.add(item.localPath);
        return paths;
    }
    void removeMissingSuggestions(java.util.Set<String> missing) {
        removeSuggestions(item -> missing.contains(item.localPath));
    }
    private void removeSuggestions(java.util.function.Predicate<ReceiveNotifications.Receipt> matches) {
        boolean removed=false;
        for(java.util.Iterator<Map.Entry<String,ReceiveNotifications.Receipt>> it=items.entrySet().iterator();it.hasNext();) {
            Map.Entry<String,ReceiveNotifications.Receipt> item=it.next();
            if(suggested.containsKey(item.getKey()) && matches.test(item.getValue())) {
                it.remove();forgetSuggestion(item.getKey());pendingRemoval.remove(item.getKey());pendingConsumed.remove(item.getKey());removed=true;
            }
        }
        if(!removed)return;
        if(pendingRemoval.isEmpty()) {main.removeCallbacks(removeExported);removalDeadline=0;}
        save();changed.run();
    }
    /** Only the overlay's actually visible, idle cards spend their display budget. */
    void setVisibleSuggestions(java.util.Set<String> ids) {
        setVisibleSuggestions("overlay",ids);
    }
    void setVisibleSuggestions(String surface,java.util.Set<String> ids) {
        suggestionSurfaces.put(surface,new java.util.HashSet<>(ids));
        java.util.Set<String> next=new java.util.HashSet<>();
        for(java.util.Set<String> showing:suggestionSurfaces.values())next.addAll(showing);
        next.retainAll(suggested.keySet());
        if(next.equals(visibleSuggestions))return;
        spendVisibleTime();
        visibleSuggestions.clear();visibleSuggestions.addAll(next);
        scheduleSuggestionExpiry();save();
    }
    private void spendVisibleTime() {
        long now=android.os.SystemClock.uptimeMillis();
        long elapsed=now-suggestionClock;
        if(suggestionInteractions.isEmpty())for(String id:visibleSuggestions)
            suggestionRemaining.computeIfPresent(id,(key,left) -> Math.max(0,left-elapsed));
        suggestionClock=now;
    }
    private void scheduleSuggestionExpiry() {
        main.removeCallbacks(expireVisibleSuggestions);
        if(!suggestionInteractions.isEmpty())return;
        long delay=Long.MAX_VALUE;
        for(String id:visibleSuggestions)delay=Math.min(delay,suggestionRemaining.get(id));
        if(delay!=Long.MAX_VALUE)main.postDelayed(expireVisibleSuggestions,delay);
    }
    private final Runnable expireVisibleSuggestions=() -> {
        spendVisibleTime();
        removeSuggestions(item -> visibleSuggestions.contains(item.id) && suggestionRemaining.get(item.id)<=0);
        scheduleSuggestionExpiry();
    };
    void suggestionInteraction(String surface,boolean interacting) {
        if(suggestionInteractions.contains(surface)==interacting)return;
        spendVisibleTime();
        if(interacting)suggestionInteractions.add(surface);else suggestionInteractions.remove(surface);
        scheduleSuggestionExpiry();save();
    }
    private void forgetSuggestion(String id) {
        for(java.util.Set<String> showing:suggestionSurfaces.values())showing.remove(id);
        suggested.remove(id);suggestionRemaining.remove(id);visibleSuggestions.remove(id);
        if(visibleSuggestions.isEmpty())main.removeCallbacks(expireVisibleSuggestions);
    }
    void suggest(List<RecentMediaSuggestions.Media> media) {
        LinkedHashMap<String,ReceiveNotifications.Receipt> next=new LinkedHashMap<>();
        long now=System.currentTimeMillis();
        for(RecentMediaSuggestions.Media entry:media)if(!contains(entry.uri,null)) {
            String id="shelf:"+UUID.randomUUID();suggested.put(id,now);suggestionRemaining.put(id,SUGGESTION_DURATION_MS);
            next.put(id,new ReceiveNotifications.Receipt(id,"1","暂存",null,entry.name,entry.uri,0));
        }
        if(next.isEmpty())return;
        next.putAll(items);items.clear();items.putAll(next);save();changed.run();
    }
    void clearSuggestions() {
        if(suggested.isEmpty())return;
        for(String id:suggested.keySet())items.remove(id);
        suggested.clear();suggestionRemaining.clear();visibleSuggestions.clear();suggestionSurfaces.clear();main.removeCallbacks(expireVisibleSuggestions);save();changed.run();
    }
    void dismissSuggestions(java.util.Set<String> ids) {removeSuggestions(item -> ids.contains(item.id));}

    void exported(List<ReceiveNotifications.Receipt> exported, boolean accepted) {
        exported(exported,accepted,item -> true);
    }
    void exported(List<ReceiveNotifications.Receipt> exported,boolean accepted,java.util.function.Predicate<ReceiveNotifications.Receipt> consumed) {
        if (!accepted) return;
        boolean suggestionsRemoved=false;
        for (ReceiveNotifications.Receipt item : exported)
            if (items.get(item.id) == item) {
                if(isSuggested(item.id)) {
                    items.remove(item.id);forgetSuggestion(item.id);suggestionsRemoved=true;
                } else {pendingRemoval.put(item.id, item);pendingConsumed.put(item.id,consumed);}
            }
        if(suggestionsRemoved)save();
        if (pendingRemoval.isEmpty()) {if(suggestionsRemoved)changed.run();return;}
        removalDeadline = android.os.SystemClock.uptimeMillis() + 3000;
        main.removeCallbacks(removeExported); main.postDelayed(removeExported, 3000);
        changed.run();
    }

    private final Runnable removeExported = this::removeExported;
    private void removeExported() {
        for (Map.Entry<String, ReceiveNotifications.Receipt> entry : pendingRemoval.entrySet())
            if(pendingConsumed.get(entry.getKey()).test(entry.getValue())) {
                items.remove(entry.getKey(), entry.getValue());forgetSuggestion(entry.getKey());
            }
        pendingRemoval.clear();pendingConsumed.clear(); removalDeadline = 0;
        // Only references disappear. Original files and a target's in-progress
        // read of a copied drop must survive the three-second UI grace period.
        save(); changed.run();
    }

    boolean cancelRemoval() {
        if (pendingRemoval.isEmpty()) return false;
        main.removeCallbacks(removeExported); pendingRemoval.clear();pendingConsumed.clear(); removalDeadline = 0;
        return true;
    }
    int removalSeconds() {
        return pendingRemoval.isEmpty() ? 0 : Math.max(1, (int)Math.ceil((removalDeadline - android.os.SystemClock.uptimeMillis()) / 1000d));
    }
    boolean pendingRemoval(String id) { return pendingRemoval.containsKey(id); }
    void clear() {
        cancelRemoval(); items.clear(); suggested.clear();suggestionRemaining.clear();visibleSuggestions.clear();suggestionSurfaces.clear();main.removeCallbacks(expireVisibleSuggestions);save(); changed.run();
    }
    void remove(String id) {
        pendingRemoval.remove(id);pendingConsumed.remove(id); items.remove(id);forgetSuggestion(id); save(); changed.run();
    }
    private void save() {
        if (!loaded) return; // Loading merges any drops received during startup before the first write.
        spendVisibleTime();
        JSONArray records = new JSONArray();
        for (ReceiveNotifications.Receipt item : items.values()) {
            JSONObject record = new JSONObject();
            try {
                record.put("id", item.id); record.put("path", item.localPath); record.put("name", item.fileName);
                if(suggested.containsKey(item.id)) {
                    record.put("suggested",true);record.put("suggestedAt",suggested.get(item.id));
                    record.put("suggestionRemainingMs",suggestionRemaining.get(item.id));
                    record.put("suggestionDurationMs",SUGGESTION_DURATION_MS);
                }
                if (item.text != null) record.put("text", item.text);
                records.put(record);
            } catch (org.json.JSONException impossible) { throw new IllegalStateException(impossible); }
        }
        String encoded = records.toString();
        io.execute(() -> {
            try {
                File partial = new File(file.getPath() + ".part");
                Files.write(partial.toPath(), encoded.getBytes(StandardCharsets.UTF_8));
                java.nio.file.Files.move(partial.toPath(), file.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
            } catch (java.io.IOException failure) { android.util.Log.w("GlobalSend", "Cannot save temporary shelf", failure); }
        });
    }
}
