package dev.globalsend.globalsend;

import android.Manifest;
import android.app.Activity;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.Consumer;
import org.json.JSONObject;

/** Explicit remote URL intents only; never reads ordinary received text. */
final class IntegrationUrlRequests {
    static final String CHANNEL="globalsend-open-url";
    private static final int NOTICE_ID=7861;
    private static IntegrationUrlRequests instance;
    static synchronized IntegrationUrlRequests get(Context context) {
        if(instance==null || !instance.context.getPackageName().equals(context.getPackageName())) instance=new IntegrationUrlRequests(context);
        return instance;
    }
    final Context context;
    final SharedPreferences preferences;
    final Handler main=new Handler(Looper.getMainLooper());
    final ExecutorService worker=Executors.newSingleThreadExecutor();
    private final Map<String,List<Consumer<Map<String,Object>>>> inflight=new java.util.HashMap<>();
    private final Runnable startRuntime;
    IntegrationUrlRequests(Context context) {
        this(context,()->NativeReceiveRuntime.ensure(context));
    }
    IntegrationUrlRequests(Context context,Runnable startRuntime) {
        this.context=context.getApplicationContext();preferences=this.context.getSharedPreferences("integration-url-requests",Context.MODE_PRIVATE);this.startRuntime=startRuntime;
    }
    static String key(String source,String id) { return source+":"+id; }
    static long expiry(String value) {
        for(String pattern:new String[]{"yyyy-MM-dd'T'HH:mm:ss.SSSXXX","yyyy-MM-dd'T'HH:mm:ssXXX"}) {
            java.text.SimpleDateFormat format=new java.text.SimpleDateFormat(pattern,java.util.Locale.ROOT);format.setLenient(false);
            java.text.ParsePosition position=new java.text.ParsePosition(0);java.util.Date parsed=format.parse(value,position);
            if(parsed!=null && position.getIndex()==value.length()) return parsed.getTime();
        }
        return 0;
    }
    static boolean validUrl(String url) {
        try {
            java.net.URI value=new java.net.URI(url);
            return url.length()<=4096 && ("http".equalsIgnoreCase(value.getScheme())||"https".equalsIgnoreCase(value.getScheme())) && value.getHost()!=null && !value.getHost().isEmpty() && value.getUserInfo()==null;
        } catch(java.net.URISyntaxException malformed) { return false; }
    }
    JSONObject record(String key) {
        try {String raw=preferences.getString("request:"+key,null);return raw==null?null:new JSONObject(raw);}
        catch(org.json.JSONException malformed) {return null;}
    }
    private Map<String,Object> result(JSONObject record) {
        Map<String,Object> value=IntegrationWire.object("sourceDeviceId",record.optString("sourceDeviceId"),"requestId",record.optString("requestId"),"state",record.optString("state"),"resultId",record.optString("resultId"));
        if(record.optJSONObject("error")!=null) value.put("error",IntegrationWire.json(record.optJSONObject("error")));
        return value;
    }
    private void save(String key,JSONObject record) {
        if(!preferences.edit().putString("request:"+key,record.toString()).commit()) throw new IllegalStateException("无法保存网页请求");
    }
    private Map<String,Object> finish(String key,JSONObject record,String state,String code,String message) {
        try {
            record.put("state",state);record.put("resultId",UUID.randomUUID().toString());
            record.remove("error");if(code!=null) record.put("error",new JSONObject(IntegrationWire.object("code",code,"message",message)));
            if(!"needs_tap".equals(state)) record.remove("url");
            Map<String,Object> value=result(record);
            if(!preferences.edit().putString("request:"+key,record.toString()).putString("result:"+key,IntegrationWire.encode(value)).commit()) throw new IllegalStateException("无法保存网页回执");
            if(!"needs_tap".equals(state)) cancelNotice(key);
            return value;
        } catch(org.json.JSONException impossible) {throw new IllegalStateException(impossible);}
    }
    void receive(Map<String,Object> request,Activity foreground,Consumer<Map<String,Object>> completed) {
        // Capture the Activity reference on the main thread; re-check focus at dispatch.
        worker.execute(()->{
            String source=String.valueOf(request.getOrDefault("sourceDeviceId","")),id=String.valueOf(request.getOrDefault("requestId",""));
            String key=key(source,id),url=String.valueOf(request.getOrDefault("url","")),expires=String.valueOf(request.getOrDefault("expiresAt",""));
            if(source.isEmpty()||source.length()>128||!IntegrationWire.uuid(id)||!validUrl(url)||expiry(expires)==0) {
                main.post(()->completed.accept(IntegrationWire.object("state","failed","error",IntegrationWire.object("code","invalid_url","message","网页请求无效"))));return;
            }
            if(inflight.containsKey(key)) {inflight.get(key).add(completed);return;}
            inflight.put(key,new ArrayList<>(java.util.Collections.singletonList(completed)));
            JSONObject record=record(key);
            try {
                if(record!=null) {
                    if("needs_tap".equals(record.optString("state")) && record.optLong("expiresMs")<=System.currentTimeMillis()) {
                        Map<String,Object> value=finish(key,record,"expired",null,null);deliver(key,value,completed);return;
                    }
                    if(!"dispatching".equals(record.optString("state"))) {
                        Map<String,Object> value=result(record);deliver(key,value,completed);return;
                    }
                    // A process may have ended between the durable dispatch mark
                    // and Shell handoff. Never auto-open that request again.
                } else {
                    record=new JSONObject(request);record.put("expiresMs",Math.min(expiry(expires),System.currentTimeMillis()+120000));
                    record.put("token",UUID.randomUUID().toString());record.put("state","dispatching");
                    save(key,record);
                    preferences.edit().putString("token:"+record.getString("token"),key).commit();
                    if(record.optLong("expiresMs")<=System.currentTimeMillis()) {
                        Map<String,Object> value=finish(key,record,"expired",null,null);deliver(key,value,completed);return;
                    }
                    JSONObject dispatch=record;
                    main.post(()->dispatch(key,dispatch,foreground,completed));return;
                }
                JSONObject uncertain=record;
                main.post(()->notifyForTap(key,uncertain,completed));
            } catch(Exception failure) {
                deliver(key,IntegrationWire.object("state","failed","error",IntegrationWire.object("code","storage_failed","message","无法保存网页请求")),completed);
            }
        });
    }
    private void dispatch(String key,JSONObject record,Activity activity,Consumer<Map<String,Object>> completed) {
        if(activity==null || activity.isFinishing() || !activity.hasWindowFocus()) {notifyForTap(key,record,completed);return;}
        if(record.optLong("expiresMs")<=System.currentTimeMillis()) {completeAsync(key,record,"expired",null,null,completed);return;}
        try {
            activity.startActivity(new Intent(Intent.ACTION_VIEW,Uri.parse(record.optString("url"))));
            completeAsync(key,record,"launch_accepted",null,null,completed);
        } catch(RuntimeException blocked) {completeAsync(key,record,"failed","launch_failed","无法打开默认浏览器",completed);}
    }
    private void notifyForTap(String key,JSONObject record,Consumer<Map<String,Object>> completed) {
        long remaining=record.optLong("expiresMs")-System.currentTimeMillis();
        if(remaining<=0) {completeAsync(key,record,"expired",null,null,completed);return;}
        NotificationManager manager=context.getSystemService(NotificationManager.class);
        if(Build.VERSION.SDK_INT>=26) manager.createNotificationChannel(new NotificationChannel(CHANNEL,"打开设备网页",NotificationManager.IMPORTANCE_HIGH));
        if((Build.VERSION.SDK_INT>=33&&context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED)||!manager.areNotificationsEnabled()||Build.VERSION.SDK_INT>=26&&manager.getNotificationChannel(CHANNEL).getImportance()==NotificationManager.IMPORTANCE_NONE) {
            completeAsync(key,record,"failed","notification_unavailable","接收设备未允许通知，无法提供网页打开按钮",completed);return;
        }
        try {
            Intent intent=new Intent(context,IntegrationUrlActivity.class).setData(new Uri.Builder().scheme("globalsend-integration").authority("open").appendPath(record.optString("token")).build());
            PendingIntent action=PendingIntent.getActivity(context,0,intent,PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_ONE_SHOT|PendingIntent.FLAG_CANCEL_CURRENT);
            Notification.Builder notice=Build.VERSION.SDK_INT>=26?new Notification.Builder(context,CHANNEL):new Notification.Builder(context);
            notice.setSmallIcon(android.R.drawable.ic_menu_view).setContentTitle("拾时请求打开网页").setContentText("点按在浏览器中打开")
                .setContentIntent(action).setAutoCancel(true).setOnlyAlertOnce(true).setCategory(Notification.CATEGORY_MESSAGE);
            if(Build.VERSION.SDK_INT>=26) notice.setTimeoutAfter(remaining);
            manager.notify("integration:"+key,NOTICE_ID,notice.build());
            completeAsync(key,record,"needs_tap",null,null,completed);
            main.postDelayed(()->worker.execute(()->expire(key)),remaining);
        } catch(RuntimeException unavailable) {completeAsync(key,record,"failed","notification_unavailable","无法显示网页打开通知",completed);}
    }
    private void completeAsync(String key,JSONObject record,String state,String code,String message,Consumer<Map<String,Object>> completed) {
        worker.execute(()->{
            Map<String,Object> value;
            try {value=finish(key,record,state,code,message);}
            catch(RuntimeException unavailable) {value=IntegrationWire.object("sourceDeviceId",record.optString("sourceDeviceId"),"requestId",record.optString("requestId"),"state","failed","error",IntegrationWire.object("code","storage_failed","message","无法保存网页回执"));}
            deliver(key,value,completed);
        });
    }
    private void deliver(String key,Map<String,Object> value,Consumer<Map<String,Object>> fallback) {
        List<Consumer<Map<String,Object>>> callbacks=inflight.remove(key);
        if(callbacks==null) callbacks=new ArrayList<>();
        if(!callbacks.contains(fallback)) callbacks.add(fallback);
        List<Consumer<Map<String,Object>>> recipients=callbacks;
        main.post(()->{for(Consumer<Map<String,Object>> callback:recipients) callback.accept(value);});
    }
    private void expire(String key) {
        JSONObject record=record(key);
        if(record==null || !"needs_tap".equals(record.optString("state")) || record.optLong("expiresMs")>System.currentTimeMillis()) return;
        Map<String,Object> value=finish(key,record,"expired",null,null);main.post(()->IntegrationBridge.publishResult(value));
    }
    void clicked(Activity activity,String token) {
        worker.execute(()->{
            String key=token==null?null:preferences.getString("token:"+token,null);JSONObject record=key==null?null:record(key);
            if(record==null || !token.equals(record.optString("token"))) {main.post(activity::finish);return;}
            if(!"needs_tap".equals(record.optString("state"))) {main.post(activity::finish);return;}
            if(record.optLong("expiresMs")<=System.currentTimeMillis()) {
                Map<String,Object> value=finish(key,record,"expired",null,null);main.post(()->{IntegrationBridge.publishResult(value);activity.finish();startRuntime.run();});return;
            }
            inflight.put(key,new ArrayList<>());
            try {record.put("state","dispatching");save(key,record);}catch(org.json.JSONException impossible){throw new IllegalStateException(impossible);}
            main.post(()->{
                String state="launch_accepted",code=null,message=null;
                try {activity.startActivity(new Intent(Intent.ACTION_VIEW,Uri.parse(record.optString("url"))));}
                catch(RuntimeException blocked) {state="failed";code="launch_failed";message="无法打开默认浏览器";}
                completeAsync(key,record,state,code,message,value->{
                    IntegrationBridge.publishResult(value);activity.finish();
                    startRuntime.run(); // Same receiver engine; pending results survive its startup.
                });
            });
        });
    }
    List<Map<String,Object>> pendingResults() {
        List<Map<String,Object>> results=new ArrayList<>();
        for(String key:preferences.getAll().keySet()) if(key.startsWith("result:")) {
            try {results.add(IntegrationWire.json(new JSONObject(preferences.getString(key,"{}"))));}
            catch(org.json.JSONException malformed) {android.util.Log.w("GlobalSend","Invalid integration result");}
        }
        return results;
    }
    void acknowledge(String source,String id,String resultId) {
        String key="result:"+key(source,id);
        try {
            JSONObject result=new JSONObject(preferences.getString(key,"{}"));
            if(resultId!=null && resultId.equals(result.optString("resultId"))) preferences.edit().remove(key).commit();
        }catch(org.json.JSONException malformed) { }
    }
    private void cancelNotice(String key) {context.getSystemService(NotificationManager.class).cancel("integration:"+key,NOTICE_ID);}
}
