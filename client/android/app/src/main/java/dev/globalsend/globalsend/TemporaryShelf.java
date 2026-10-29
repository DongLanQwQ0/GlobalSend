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
    final LinkedHashMap<String, ReceiveNotifications.Receipt> items = new LinkedHashMap<>();
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
            try {
                if (file.isFile()) {
                    JSONArray records = new JSONArray(new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8));
                    for (int i = 0; i < records.length(); i++) {
                        JSONObject record = records.getJSONObject(i);
                        String path = record.optString("path");
                        // External originals may have been removed while the app was stopped.
                        if (!path.isEmpty() && !path.startsWith("content://") && !new File(path).exists()) continue;
                        restored.add(new ReceiveNotifications.Receipt(record.getString("id"), "1", "暂存",
                            record.has("text") ? record.getString("text") : null, record.optString("name"), path, 0));
                    }
                }
            } catch (java.io.IOException | org.json.JSONException unavailable) {
                android.util.Log.w("GlobalSend", "Cannot restore temporary shelf", unavailable);
            }
            main.post(() -> {
                for (ReceiveNotifications.Receipt receipt : restored)
                    if (!contains(receipt.localPath, receipt.text)) items.put(receipt.id, receipt);
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

    void exported(List<ReceiveNotifications.Receipt> exported, boolean accepted) {
        exported(exported,accepted,item -> true);
    }
    void exported(List<ReceiveNotifications.Receipt> exported,boolean accepted,java.util.function.Predicate<ReceiveNotifications.Receipt> consumed) {
        if (!accepted) return;
        for (ReceiveNotifications.Receipt item : exported)
            if (items.get(item.id) == item) {pendingRemoval.put(item.id, item);pendingConsumed.put(item.id,consumed);}
        if (pendingRemoval.isEmpty()) return;
        removalDeadline = android.os.SystemClock.uptimeMillis() + 3000;
        main.removeCallbacks(removeExported); main.postDelayed(removeExported, 3000);
        changed.run();
    }

    private final Runnable removeExported = this::removeExported;
    private void removeExported() {
        for (Map.Entry<String, ReceiveNotifications.Receipt> entry : pendingRemoval.entrySet())
            if(pendingConsumed.get(entry.getKey()).test(entry.getValue()))items.remove(entry.getKey(), entry.getValue());
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
        cancelRemoval(); items.clear(); save(); changed.run();
    }
    void remove(String id) {
        pendingRemoval.remove(id);pendingConsumed.remove(id); items.remove(id); save(); changed.run();
    }
    private void save() {
        if (!loaded) return; // Loading merges any drops received during startup before the first write.
        JSONArray records = new JSONArray();
        for (ReceiveNotifications.Receipt item : items.values()) {
            JSONObject record = new JSONObject();
            try {
                record.put("id", item.id); record.put("path", item.localPath); record.put("name", item.fileName);
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
