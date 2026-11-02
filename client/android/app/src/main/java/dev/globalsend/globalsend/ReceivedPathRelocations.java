package dev.globalsend.globalsend;

import android.content.Context;
import android.util.AtomicFile;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import org.json.JSONObject;

/** Durable aliases shared by Dart's received-file index and native references. */
final class ReceivedPathRelocations {
    private static final Object LOCK=new Object();
    private static final Map<String,Map<String,String>> snapshots=new HashMap<>();
    private static File file(Context context){return new File(context.getFilesDir(),"received-path-relocations.json");}
    private static Map<String,String> json(File file,String property) throws IOException {
        Map<String,String> result=new LinkedHashMap<>();
        if(!file.isFile() && (property!=null || !new File(file.getPath()+".bak").isFile()))return result;
        try {
            byte[] bytes=property==null?new AtomicFile(file).readFully():Files.readAllBytes(file.toPath());
            JSONObject data=new JSONObject(new String(bytes,StandardCharsets.UTF_8));
            if(property!=null){data=data.optJSONObject(property);if(data==null)return result;}
            for(java.util.Iterator<String> keys=data.keys();keys.hasNext();){String key=keys.next();String value=data.optString(key);if(!key.isEmpty() && !value.isEmpty())result.put(key,value);}
            return result;
        }catch(org.json.JSONException invalid){throw new IOException("Cannot read received-file relocations",invalid);}
    }
    static Map<String,String> read(Context context) throws IOException {
        synchronized(LOCK){
            String key=file(context).getAbsolutePath();Map<String,String> cached=snapshots.get(key);if(cached!=null)return cached;
            Map<String,String> aliases=json(file(context),null);
            // Earlier builds already committed these aliases before the native
            // shelf knew about them. Recover them before pruning a missing path.
            String configured=System.getenv("GLOBALSEND_DATA_DIR");
            File state=configured==null || configured.isEmpty()?context.getFilesDir():new File(configured);
            aliases.putAll(json(new File(state,"saved-files.json"),"relocatedLocations"));
            Map<String,String> snapshot=Collections.unmodifiableMap(aliases);snapshots.put(key,snapshot);return snapshot;
        }
    }
    static String resolve(Context context,String path) throws IOException {
        return resolve(read(context),path);
    }
    static String resolve(Map<String,String> aliases,String path) {
        if(path==null || path.isEmpty())return path;
        String current=path;java.util.Set<String> seen=new HashSet<>();
        while(seen.add(current)){
            String next=aliases.get(current);
            if(next==null && !current.startsWith("content://"))next=aliases.get(new File(current).getAbsolutePath());
            if(next==null || next.equals(current))break;current=next;
        }
        return current;
    }
    static void commit(Context context,Map<String,String> incoming) throws IOException {
        synchronized(LOCK){
            Map<String,String> aliases=new LinkedHashMap<>(read(context));aliases.putAll(incoming);
            for(String key:aliases.keySet().toArray(new String[0]))aliases.put(key,resolve(aliases,aliases.get(key)));
            AtomicFile target=new AtomicFile(file(context));FileOutputStream stream=null;
            try {stream=target.startWrite();stream.write(new JSONObject(aliases).toString().getBytes(StandardCharsets.UTF_8));target.finishWrite(stream);}
            catch(IOException error){if(stream!=null)target.failWrite(stream);throw error;}
            snapshots.put(file(context).getAbsolutePath(),Collections.unmodifiableMap(aliases));
        }
    }
    static ReceiveNotifications.Receipt resolve(Context context,ReceiveNotifications.Receipt receipt) throws IOException {
        String path=resolve(context,receipt.localPath);
        return path.equals(receipt.localPath)?receipt:new ReceiveNotifications.Receipt(receipt.id,receipt.version,receipt.source,receipt.text,receipt.fileName,path,receipt.size);
    }
    static void forgetForTest(Context context){synchronized(LOCK){snapshots.remove(file(context).getAbsolutePath());}}
}
