package dev.globalsend.globalsend;

import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.Message;
import android.os.Messenger;
import android.os.RemoteException;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Consumer;
import org.json.JSONObject;

/** Versioned, explicit app-to-app Messenger endpoint. No file or credential access. */
public class IntegrationService extends Service {
    private final Handler main=new Handler(Looper.getMainLooper());
    private final ExecutorService identity=Executors.newSingleThreadExecutor();
    private final Messenger incoming=new Messenger(new Handler(Looper.getMainLooper()) {
        @Override public void handleMessage(Message message) {accept(message);}
    });
    @Override public IBinder onBind(Intent intent) {return incoming.getBinder();}
    void accept(Message message) {
        final Messenger reply=message.replyTo;
        if(reply==null) return;
        final int uid=message.sendingUid,sequence=message.arg1,what=message.what;
        final long receivedAt=System.currentTimeMillis();
        final String raw;
        try {raw=message.getData().getString("request","");}
        catch(RuntimeException malformed) {respond(reply,sequence,IntegrationWire.error("","invalid_request","请求格式无效",false),null);return;}
        identity.execute(()->{
            JSONObject request;
            try {
                if(raw.length()>65536) throw new IllegalArgumentException();
                request=new JSONObject(raw);
            }catch(Exception malformed){respond(reply,sequence,IntegrationWire.error("","invalid_request","请求格式无效",false),null);return;}
            String id=request.optString("requestId"),method=request.optString("method");
            if(what!=1||!IntegrationWire.uuid(id)) {respond(reply,sequence,IntegrationWire.error(id,"invalid_request","请求标识无效",false),null);return;}
            if(request.optInt("v",0)!=1) {respond(reply,sequence,IntegrationWire.error(id,"unsupported_version","不支持此集成协议版本",false),null);return;}
            if(!java.util.Arrays.asList("hello","list_devices","send_open_url","send_link","status").contains(method)) {respond(reply,sequence,IntegrationWire.error(id,"invalid_request","不支持此操作",false),null);return;}
            IntegrationAssociations associations=new IntegrationAssociations(this);
            IntegrationAssociations.Caller caller=associations.caller(uid);
            if(caller==null) {respond(reply,sequence,IntegrationWire.error(id,"caller_not_allowed","此应用不能访问 GlobalSend",false),null);return;}
            if(!associations.authorized(caller)) {
                PendingIntent action=associations.consent(caller);
                Map<String,Object> value="hello".equals(method) ? IntegrationWire.success(id,hello(false,"required")) : IntegrationWire.error(id,"authorization_required","请先在 GlobalSend 允许应用联动",false);
                respond(reply,sequence,value,action);return;
            }
            Map<String,Object> body=IntegrationWire.json(request);
            main.post(()->{
                AtomicBoolean finished=new AtomicBoolean();
                Runnable timeout=()->{
                    if(finished.compareAndSet(false,true)) respond(reply,sequence,IntegrationWire.error(id,"timeout_unknown","请求结果尚未确认，请使用原请求查询",true),null);
                };
                main.postDelayed(timeout,Math.max(0,5000-(System.currentTimeMillis()-receivedAt)));
                try {
                    dispatch(caller,body,receivedAt,result->{
                        if(!finished.compareAndSet(false,true)) return;
                        main.removeCallbacks(timeout);
                        Map<String,Object> response=associations.authorized(caller) ? IntegrationWire.publicResponse(id,method,result) : IntegrationWire.error(id,"authorization_required","应用联动已撤销，请重新关联",false);
                        if("hello".equals(method)&&Boolean.TRUE.equals(response.get("ok"))) {
                            @SuppressWarnings("unchecked") Map<String,Object> value=(Map<String,Object>)response.get("result");
                            value.putAll(hello(Boolean.TRUE.equals(value.get("connected")),"authorized"));
                        }
                        respond(reply,sequence,response,null);
                    });
                }catch(RuntimeException unavailable) {
                    main.removeCallbacks(timeout);
                    if(finished.compareAndSet(false,true)) respond(reply,sequence,IntegrationWire.error(id,"not_connected","GlobalSend 尚未就绪",true),null);
                }
            });
        });
    }
    /** Kept overridable for host tests without loading a native Flutter engine. */
    protected void dispatch(IntegrationAssociations.Caller caller,Map<String,Object> request,long receivedAt,Consumer<Object> completed) {
        IntegrationBridge.request(this,caller,request,receivedAt,completed);
    }
    private Map<String,Object> hello(boolean connected,String state) {
        String version="";
        try {version=getPackageManager().getPackageInfo(getPackageName(),0).versionName;}catch(android.content.pm.PackageManager.NameNotFoundException impossible){ }
        return IntegrationWire.object("protocolVersion",1,"appVersion",version==null?"":version,"connected",connected,"associationState",state,"capabilities",java.util.Arrays.asList("list_devices","send_open_url","send_link"));
    }
    private void respond(Messenger target,int sequence,Map<String,Object> body,PendingIntent association) {
        Message response=Message.obtain(null,1);response.arg1=sequence;Bundle data=new Bundle();data.putString("response",IntegrationWire.encode(body));
        if(association!=null)data.putParcelable("association_intent",association);response.setData(data);
        try {target.send(response);}catch(RemoteException callerGone){ /* Durable operations are not canceled when the caller leaves. */ }
    }
    @Override public void onDestroy() {identity.shutdown();super.onDestroy();}
}
