package dev.globalsend.globalsend;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.os.Handler;
import android.os.Looper;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;
import java.util.function.Supplier;

/** Internal engine bridge, separate from ordinary text, sharing and receiver UI. */
final class IntegrationBridge {
    private static IntegrationBridge current;
    private final Context context;
    private final MethodChannel channel;
    private final Handler main=new Handler(Looper.getMainLooper());
    private final List<Pending> pending=new ArrayList<>();
    private boolean ready;
    private final IntegrationUrlRequests urls;
    private static final class Pending {
        final String caller;
        final Map<String,Object> request;
        final long receivedAt;
        final Consumer<Object> reply;
        final java.util.function.BooleanSupplier authorized;
        Pending(String caller,Map<String,Object> request,long receivedAt,Consumer<Object> reply,java.util.function.BooleanSupplier authorized) {
            this.caller=caller;this.request=request;this.receivedAt=receivedAt;this.reply=reply;this.authorized=authorized;
        }
    }
    IntegrationBridge(Context context,BinaryMessenger messenger,Supplier<? extends Activity> activity) {
        this.context=context.getApplicationContext();this.channel=new MethodChannel(messenger,"dev.globalsend/integration");
        urls=IntegrationUrlRequests.get(this.context);current=this;
        channel.setMethodCallHandler((call,result)->{
            switch(call.method) {
                case "ready":
                    ready=true;result.success(null);
                    List<Pending> queued=new ArrayList<>(pending);pending.clear();for(Pending item:queued) dispatch(item);
                    break;
                case "openUrlIntent":
                    if(!(call.arguments instanceof Map)) {result.error("INVALID_REQUEST","网页请求无效",null);break;}
                    @SuppressWarnings("unchecked") Map<String,Object> arguments=(Map<String,Object>)call.arguments;
                    urls.receive(arguments,activity.get(),result::success);break;
                case "pendingResults":
                    urls.worker.execute(()->{List<Map<String,Object>> values=urls.pendingResults();main.post(()->result.success(values));});break;
                case "ackResult":
                    String source=call.argument("sourceDeviceId"),id=call.argument("requestId"),revision=call.argument("resultId");
                    urls.worker.execute(()->{urls.acknowledge(source,id,revision);main.post(()->result.success(null));});break;
                case "manageAssociations":
                    context.startActivity(new Intent(context,IntegrationAssociationsActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));result.success(null);break;
                default:result.notImplemented();
            }
        });
    }
    static void request(Context context,IntegrationAssociations.Caller caller,Map<String,Object> request,long receivedAt,Consumer<Object> completed) {
        IntegrationAssociations associations=new IntegrationAssociations(context);
        // Ensure creates or reuses the one existing receiver engine. It never
        // creates another Activity or replaces a currently running engine.
        NativeReceiveRuntime runtime=NativeReceiveRuntime.ensure(context);
        runtime.integration.forward(caller.packageName,request,receivedAt,completed,()->associations.authorized(caller));
    }
    void forward(String caller,Map<String,Object> request,long receivedAt,Consumer<Object> completed) {
        forward(caller,request,receivedAt,completed,()->true);
    }
    void forward(String caller,Map<String,Object> request,long receivedAt,Consumer<Object> completed,java.util.function.BooleanSupplier authorized) {
        Pending item=new Pending(caller,request,receivedAt,completed,authorized);
        if(ready)dispatch(item);else pending.add(item);
    }
    private void dispatch(Pending request) {
        if(!request.authorized.getAsBoolean()) {
            request.reply.accept(IntegrationWire.error(String.valueOf(request.request.get("requestId")),"authorization_required","请先在 GlobalSend 允许应用联动",false));return;
        }
        channel.invokeMethod("request",IntegrationWire.object("callerAppId",request.caller,"request",request.request,"receivedAtMillis",request.receivedAt),new MethodChannel.Result(){
            @Override public void success(Object value) {request.reply.accept(value);}
            @Override public void error(String code,String message,Object details) {
                request.reply.accept(IntegrationWire.error(String.valueOf(request.request.get("requestId")),"not_connected","GlobalSend 暂时不可用",true));
            }
            @Override public void notImplemented() {
                // A cold/hot-restarting Dart handler is not an unsupported app.
                // Keep the exact operation until the explicit ready handshake.
                ready=false;pending.add(request);
            }
        });
    }
    static void publishResult(Map<String,Object> value) {
        IntegrationBridge bridge=current;
        if(bridge!=null && bridge.ready) bridge.channel.invokeMethod("urlIntentResult",value);
    }
}
