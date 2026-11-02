package dev.globalsend.globalsend;

import android.content.Context;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardOpenOption;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicBoolean;
import org.json.JSONObject;

/** Explicit, temporary diagnostics for this app's own drag/provider events. */
final class DragDiagnostics {
    static final String DIRECTORY="diagnostics/native-drag112";
    static final int MAX_BYTES=65536;
    private static final ExecutorService io=Executors.newSingleThreadExecutor(task -> {
        Thread worker=new Thread(task,"GlobalSend-drag-diagnostics");worker.setDaemon(true);return worker;
    });
    private static final AtomicBoolean initializing=new AtomicBoolean();
    private static File marker,log;
    private static String application="";
    private static boolean enabledSession;

    static void initialize(Context context) {
        if(!initializing.compareAndSet(false,true))return;
        Context app=context.getApplicationContext();
        io.execute(() -> {
            try {
                File cache=app.getExternalCacheDir();if(cache==null)return;
                File directory=new File(cache,DIRECTORY);
                if(!directory.isDirectory() && !directory.mkdirs())return;
                marker=new File(directory,"enabled");log=new File(directory,"drag.log");
                application=app.getPackageName()+" version="+app.getPackageManager().getPackageInfo(app.getPackageName(),0).versionName;
            }catch(Exception error){android.util.Log.w("GlobalSendDrag","Cannot initialize temporary drag diagnostics",error);}
        });
    }

    static void record(String event) {
        long wall=System.currentTimeMillis(),elapsed=android.os.SystemClock.elapsedRealtime();
        String thread=Thread.currentThread().getName();int caller=android.os.Binder.getCallingUid();
        String bounded=event.length()>512?event.substring(0,512):event;
        io.execute(() -> {
            // Marker checks and all writes run here, never on a gesture/UI or
            // binder thread. Removing the marker stops subsequent writes.
            if(marker==null || !marker.isFile()){enabledSession=false;return;}
            try {
                if(!enabledSession){append(wall,elapsed,"diagnostics enabled "+application,thread,caller);enabledSession=true;}
                append(wall,elapsed,bounded,thread,caller);
            }catch(Exception error){android.util.Log.w("GlobalSendDrag","Cannot write temporary drag diagnostics",error);}
        });
    }

    private static void append(long wall,long elapsed,String event,String thread,int caller) throws Exception {
        String line=new JSONObject().put("time",wall).put("elapsed",elapsed).put("pid",android.os.Process.myPid())
            .put("caller",caller).put("thread",thread).put("ioThread",Thread.currentThread().getName()).put("event",event).toString()+"\n";
        byte[] bytes=line.getBytes(StandardCharsets.UTF_8);
        StandardOpenOption mode=log.length()+bytes.length>MAX_BYTES?StandardOpenOption.TRUNCATE_EXISTING:StandardOpenOption.APPEND;
        Files.write(log.toPath(),bytes,StandardOpenOption.CREATE,mode);
    }

    // A queue barrier for host tests; no sleep or background polling required.
    static Future<?> idle(){return io.submit(() -> {});}
}
