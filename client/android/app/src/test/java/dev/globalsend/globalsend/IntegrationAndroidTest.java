package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.Manifest;
import android.app.Activity;
import android.app.Notification;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.Signature;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Message;
import android.os.Messenger;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.StandardMethodCodec;
import java.nio.ByteBuffer;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.BooleanSupplier;
import java.util.function.Consumer;
import org.json.JSONObject;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.LooperMode;

@RunWith(RobolectricTestRunner.class)
@Config(sdk=34,manifest=Config.NONE)
@LooperMode(LooperMode.Mode.PAUSED)
public class IntegrationAndroidTest {
    Context context;
    static final int CHRONA_UID=12345;
    @Before public void setup() {
        context=RuntimeEnvironment.getApplication();
        context.getSharedPreferences("integration-associations",0).edit().clear().commit();
        context.getSharedPreferences("integration-url-requests",0).edit().clear().commit();
        install(IntegrationAssociations.CHRONA,CHRONA_UID,"cert-one",1000);
    }
    private void install(String name,int uid,String certificate,long installed) {
        PackageInfo info=new PackageInfo();info.packageName=name;info.firstInstallTime=installed;info.versionName="test";
        info.applicationInfo=new ApplicationInfo();info.applicationInfo.packageName=name;info.applicationInfo.uid=uid;info.applicationInfo.name="拾时";info.applicationInfo.nonLocalizedLabel="拾时";
        info.signatures=new Signature[]{new Signature(certificate.getBytes(java.nio.charset.StandardCharsets.UTF_8))};
        Shadows.shadowOf(context.getPackageManager()).installPackage(info);
        Shadows.shadowOf(context.getPackageManager()).setApplicationIcon(name,new android.graphics.drawable.ColorDrawable(0xff7051a8));
    }
    private static void await(BooleanSupplier complete) throws Exception {
        long deadline=System.nanoTime()+Duration.ofSeconds(8).toNanos();
        while(!complete.getAsBoolean()&&System.nanoTime()<deadline) {Shadows.shadowOf(Looper.getMainLooper()).idle();Thread.sleep(5);}
        Shadows.shadowOf(Looper.getMainLooper()).idle();assertTrue("asynchronous native callback",complete.getAsBoolean());
    }
    @Test public void associationBindsExactPackageUidSignerAndInstallationAndIsRevocable() throws Exception {
        IntegrationAssociations store=new IntegrationAssociations(context);
        IntegrationAssociations.Caller caller=store.caller(CHRONA_UID);assertNotNull(caller);assertFalse(store.authorized(caller));
        install("other.same.debug.key",23456,"cert-one",1000);assertNull(store.caller(23456));
        PendingIntent consent=store.consent(caller);assertTrue(consent.isImmutable());
        assertTrue((Shadows.shadowOf(consent).getFlags()&PendingIntent.FLAG_ONE_SHOT)!=0);
        String token=Shadows.shadowOf(consent).getSavedIntent().getData().getLastPathSegment();
        assertTrue(store.approve(token));assertTrue(store.authorized(store.caller(CHRONA_UID)));assertNull(store.pending(token));
        install(IntegrationAssociations.CHRONA,CHRONA_UID,"cert-two",1000);assertFalse(store.authorized(store.caller(CHRONA_UID)));assertFalse(store.authorized(caller));
        install(IntegrationAssociations.CHRONA,CHRONA_UID,"cert-one",2000);assertFalse(store.authorized(store.caller(CHRONA_UID)));
        install(IntegrationAssociations.CHRONA,CHRONA_UID,"cert-one",1000);assertTrue(store.authorized(store.caller(CHRONA_UID)));
        store.revoke();assertFalse(store.authorized(store.caller(CHRONA_UID)));
    }
    public static class FakeService extends IntegrationService {
        int calls;Consumer<Object> reply;Map<String,Object> seen;long received;
        @Override protected void dispatch(IntegrationAssociations.Caller caller,Map<String,Object> request,long at,Consumer<Object> completed) {assertEquals(IntegrationAssociations.CHRONA,caller.packageName);calls++;seen=request;received=at;reply=completed;}
    }
    private Message rpc(FakeService service,int uid,int serial,String json,List<Message> replies) {
        Message request=Message.obtain(null,1);request.sendingUid=uid;request.arg1=serial;
        request.replyTo=new Messenger(new Handler(Looper.getMainLooper()){ @Override public void handleMessage(Message response){replies.add(Message.obtain(response));}});
        Bundle bundle=new Bundle();bundle.putString("request",json);request.setData(bundle);service.accept(request);return request;
    }
    private String json(String method,String id) {return IntegrationWire.encode(IntegrationWire.object("v",1,"requestId",id,"method",method));}
    private JSONObject body(Message message) throws Exception {return new JSONObject(message.getData().getString("response"));}
    @Test public void messengerUsesKernelUidAndEchoesSerialForAuthorizationErrorsAndLateReply() throws Exception {
        FakeService service=Robolectric.buildService(FakeService.class).create().get();List<Message> replies=new ArrayList<>();String id=UUID.randomUUID().toString();
        rpc(service,23456,11,json("hello",id),replies);await(()->replies.size()==1);
        assertEquals("caller_not_allowed",body(replies.get(0)).getJSONObject("error").getString("code"));assertEquals(11,replies.get(0).arg1);assertEquals(0,service.calls);
        rpc(service,CHRONA_UID,12,json("hello",id),replies);await(()->replies.size()==2);
        JSONObject required=body(replies.get(1)).getJSONObject("result");assertEquals("required",required.getString("associationState"));assertFalse(required.getBoolean("connected"));
        PendingIntent consent=replies.get(1).getData().getParcelable("association_intent");assertNotNull(consent);assertEquals(0,service.calls);
        IntegrationAssociations store=new IntegrationAssociations(context);assertTrue(store.approve(Shadows.shadowOf(consent).getSavedIntent().getData().getLastPathSegment()));
        rpc(service,CHRONA_UID,13,json("list_devices",id),replies);await(()->service.calls==1);assertTrue(service.received>0);
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(5));await(()->replies.size()==3);
        assertEquals(13,replies.get(2).arg1);assertEquals("timeout_unknown",body(replies.get(2)).getJSONObject("error").getString("code"));
        service.reply.accept(IntegrationWire.success(id,IntegrationWire.object("devices",new ArrayList<>())));Shadows.shadowOf(Looper.getMainLooper()).idle();assertEquals(3,replies.size());
        rpc(service,CHRONA_UID,14,json("status",id),replies);await(()->service.calls==2);
        service.reply.accept(IntegrationWire.success(id,IntegrationWire.object("requestId",id,"state","queued","token","SECRET")));
        await(()->replies.size()==4);assertEquals(14,replies.get(3).arg1);assertFalse(body(replies.get(3)).getJSONObject("result").has("token"));service.onDestroy();
    }
    @Test public void malformedRequestAndForeignCallerFieldsNeverBypassAssociation() throws Exception {
        FakeService service=Robolectric.buildService(FakeService.class).create().get();List<Message> replies=new ArrayList<>();
        rpc(service,CHRONA_UID,31,json("hello","not-a-uuid"),replies);await(()->replies.size()==1);assertEquals(31,replies.get(0).arg1);assertEquals("invalid_request",body(replies.get(0)).getJSONObject("error").getString("code"));
        rpc(service,23456,32,IntegrationWire.encode(IntegrationWire.object("v",1,"requestId",UUID.randomUUID().toString(),"method","list_devices","callerAppId",IntegrationAssociations.CHRONA,"uid",CHRONA_UID)),replies);
        await(()->replies.size()==2);assertEquals("caller_not_allowed",body(replies.get(1)).getJSONObject("error").getString("code"));assertEquals(0,service.calls);service.onDestroy();
    }
    @Test public void approvedSendLinkAndLinkStatusReachTheBridgeAndHelloAdvertisesThem() throws Exception {
        FakeService service=Robolectric.buildService(FakeService.class).create().get();
        IntegrationAssociations associations=new IntegrationAssociations(context);
        PendingIntent consent=associations.consent(associations.caller(CHRONA_UID));
        assertTrue(associations.approve(Shadows.shadowOf(consent).getSavedIntent().getData().getLastPathSegment()));
        List<Message> replies=new ArrayList<>();String id=UUID.randomUUID().toString();
        rpc(service,CHRONA_UID,51,json("send_link",id),replies);await(()->service.calls==1);
        assertEquals("send_link",service.seen.get("method"));
        service.reply.accept(IntegrationWire.success(id,IntegrationWire.object("requestId",id,"deliveryMode","link","state","sent")));
        await(()->replies.size()==1);assertEquals("sent",body(replies.get(0)).getJSONObject("result").getString("state"));
        rpc(service,CHRONA_UID,52,new JSONObject(IntegrationWire.object("v",1,"requestId",id,"method","status","deliveryMode","link")).toString(),replies);
        await(()->service.calls==2);assertEquals("link",service.seen.get("deliveryMode"));
        service.reply.accept(IntegrationWire.success(id,IntegrationWire.object("requestId",id,"deliveryMode","link","state","sent")));
        await(()->replies.size()==2);
        rpc(service,CHRONA_UID,53,json("hello",id),replies);await(()->service.calls==3);
        service.reply.accept(IntegrationWire.success(id,IntegrationWire.object("connected",true)));
        await(()->replies.size()==3);
        assertTrue(body(replies.get(2)).getJSONObject("result").getJSONArray("capabilities").toString().contains("send_link"));
        service.onDestroy();
    }
    static class FakeMessenger implements BinaryMessenger {
        BinaryMessageHandler incoming;int calls;boolean implemented=true;Object lastArguments;
        public void send(String channel,ByteBuffer message){send(channel,message,null);}
        public void send(String channel,ByteBuffer message,BinaryReply callback){
            MethodCall call=StandardMethodCodec.INSTANCE.decodeMethodCall(readable(message));
            if("request".equals(call.method)){calls++;lastArguments=call.arguments;}
            if(callback!=null) callback.reply(implemented?readable(StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(IntegrationWire.success("id",IntegrationWire.object("connected",true)))):null);
        }
        public void setMessageHandler(String channel,BinaryMessageHandler handler){incoming=handler;}
        void ready(){incoming.onMessage(readable(StandardMethodCodec.INSTANCE.encodeMethodCall(new MethodCall("ready",null))),reply->{});}
        static ByteBuffer readable(ByteBuffer value){ByteBuffer result=value.duplicate();result.flip();return result;}
    }
    @Test public void coldEngineQueuesUntilReadyAndHotRestartNotImplementedWaitsForNewHandshake() {
        FakeMessenger messenger=new FakeMessenger();IntegrationBridge bridge=new IntegrationBridge(context,messenger,()->null);List<Object> replies=new ArrayList<>();
        bridge.forward(IntegrationAssociations.CHRONA,IntegrationWire.object("requestId","id"),123,replies::add);assertEquals(0,messenger.calls);
        messenger.ready();assertEquals(1,messenger.calls);assertEquals(1,replies.size());assertEquals(123L,((Map<?,?>)messenger.lastArguments).get("receivedAtMillis"));
        messenger.implemented=false;bridge.forward(IntegrationAssociations.CHRONA,IntegrationWire.object("requestId","second"),456,replies::add);assertEquals(2,messenger.calls);assertEquals(1,replies.size());
        messenger.implemented=true;messenger.ready();assertEquals(3,messenger.calls);assertEquals(2,replies.size());
    }
    @Test public void revocationWhileEngineIsColdPreventsQueuedOperation() {
        FakeMessenger messenger=new FakeMessenger();IntegrationBridge bridge=new IntegrationBridge(context,messenger,()->null);List<Object> replies=new ArrayList<>();java.util.concurrent.atomic.AtomicBoolean authorized=new java.util.concurrent.atomic.AtomicBoolean(true);
        bridge.forward(IntegrationAssociations.CHRONA,IntegrationWire.object("requestId","id"),123,replies::add,authorized::get);authorized.set(false);messenger.ready();
        assertEquals(0,messenger.calls);assertEquals(1,replies.size());assertEquals("authorization_required",((Map<?,?>)((Map<?,?>)replies.get(0)).get("error")).get("code"));
    }
    @Test public void revocationBeforeReplyDoesNotReturnDeviceData() throws Exception {
        IntegrationAssociations store=new IntegrationAssociations(context);PendingIntent consent=store.consent(store.caller(CHRONA_UID));store.approve(Shadows.shadowOf(consent).getSavedIntent().getData().getLastPathSegment());
        FakeService service=Robolectric.buildService(FakeService.class).create().get();List<Message> replies=new ArrayList<>();String id=UUID.randomUUID().toString();
        rpc(service,CHRONA_UID,44,json("list_devices",id),replies);await(()->service.calls==1);store.revoke();service.reply.accept(IntegrationWire.success(id,IntegrationWire.object("devices",new ArrayList<>())));await(()->replies.size()==1);
        assertEquals("authorization_required",body(replies.get(0)).getJSONObject("error").getString("code"));assertFalse(body(replies.get(0)).has("result"));service.onDestroy();
    }
    private Map<String,Object> url(String id,long lifetime) {return IntegrationWire.object("sourceDeviceId","phone","requestId",id,"url","http://10.1.2.3:8765/","expiresAt",Instant.ofEpochMilli(System.currentTimeMillis()+lifetime).toString(),"callerAppId",IntegrationAssociations.CHRONA);}
    private Map<String,Object> receive(IntegrationUrlRequests requests,Map<String,Object> value,Activity activity) throws Exception {
        AtomicReference<Map<String,Object>> result=new AtomicReference<>();requests.receive(value,activity,result::set);await(()->result.get()!=null);return result.get();
    }
    public static class FocusActivity extends Activity { @Override public boolean hasWindowFocus(){return true;} }
    @Test public void foregroundOpensOnceAndDuplicateRequestDoesNotLaunchAgain() throws Exception {
        IntegrationUrlRequests requests=new IntegrationUrlRequests(context,()->{});FocusActivity activity=Robolectric.buildActivity(FocusActivity.class).setup().get();String id=UUID.randomUUID().toString();
        Map<String,Object> result=receive(requests,url(id,120000),activity);assertEquals("launch_accepted",result.get("state"));assertNotNull(Shadows.shadowOf(activity).getNextStartedActivity());
        assertEquals("launch_accepted",receive(requests,url(id,120000),activity).get("state"));assertNull(Shadows.shadowOf(activity).getNextStartedActivity());
        requests.worker.shutdown();
    }
    @Test public void backgroundNeedsTapNotificationColdClickPersistsAndOldAckCannotEraseNewResult() throws Exception {
        Shadows.shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.POST_NOTIFICATIONS);
        IntegrationUrlRequests requests=new IntegrationUrlRequests(context,()->{});String id=UUID.randomUUID().toString();
        Map<String,Object> initial=receive(requests,url(id,120000),null);assertEquals("needs_tap",initial.get("state"));assertNull(Shadows.shadowOf(RuntimeEnvironment.getApplication()).getNextStartedActivity());
        List<Notification> notices=Shadows.shadowOf(context.getSystemService(NotificationManager.class)).getAllNotifications();assertEquals(1,notices.size());
        Intent click=Shadows.shadowOf(notices.get(0).contentIntent).getSavedIntent();assertEquals(IntegrationUrlActivity.class.getName(),click.getComponent().getClassName());assertTrue(notices.get(0).contentIntent.isImmutable());
        IntegrationUrlRequests cold=new IntegrationUrlRequests(context,()->{});Activity activity=Robolectric.buildActivity(Activity.class).setup().get();
        cold.clicked(activity,click.getData().getLastPathSegment());await(()->activity.isFinishing());
        assertEquals(Intent.ACTION_VIEW,Shadows.shadowOf(activity).getNextStartedActivity().getAction());assertEquals(0,Shadows.shadowOf(context.getSystemService(NotificationManager.class)).size());
        List<Map<String,Object>> pending=cold.pendingResults();assertEquals(1,pending.size());assertEquals("launch_accepted",pending.get(0).get("state"));
        cold.acknowledge("phone",id,(String)initial.get("resultId"));assertEquals(1,cold.pendingResults().size());
        cold.acknowledge("phone",id,(String)pending.get(0).get("resultId"));assertTrue(cold.pendingResults().isEmpty());
        assertEquals("launch_accepted",receive(cold,url(id,120000),null).get("state"));assertNull(Shadows.shadowOf(activity).getNextStartedActivity());
        requests.worker.shutdown();cold.worker.shutdown();
    }
    @Test public void expiredOrNotificationBlockedNeverPretendsBrowserWasLaunched() throws Exception {
        IntegrationUrlRequests requests=new IntegrationUrlRequests(context,()->{});
        assertEquals("expired",receive(requests,url(UUID.randomUUID().toString(),-1000),null).get("state"));
        Shadows.shadowOf(RuntimeEnvironment.getApplication()).denyPermissions(Manifest.permission.POST_NOTIFICATIONS);
        Map<String,Object> blocked=receive(requests,url(UUID.randomUUID().toString(),120000),null);assertEquals("failed",blocked.get("state"));assertEquals("notification_unavailable",((Map<?,?>)blocked.get("error")).get("code"));
        assertNull(Shadows.shadowOf(RuntimeEnvironment.getApplication()).getNextStartedActivity());requests.worker.shutdown();
    }
    @Test public void publicFieldsExcludeCredentialsAndPrivatePeerAddresses() {
        Map<String,Object> peer=IntegrationWire.object("deviceId","device","name","电脑","online",true,"token","SECRET","peer","https://private","capabilities",IntegrationWire.object("openUrlIntentV1",true,"secret","SECRET"));
        String result=IntegrationWire.encode(IntegrationWire.publicResponse("id","list_devices",IntegrationWire.success("id",IntegrationWire.object("devices",java.util.Arrays.asList(peer),"updatedAt","now","token","SECRET"))));
        assertFalse(result.contains("SECRET"));assertFalse(result.contains("private"));assertTrue(result.contains("openUrlIntentV1"));
    }
    @Test public void linkCapabilityAndSentStatusSurviveNativeProjection() {
        Map<String,Object> peer=IntegrationWire.object("deviceId","ipad","platform","other","online",true,
            "capabilities",IntegrationWire.object("openUrlIntentV1",false,"sendLinkV1",true));
        Map<?,?> list=(Map<?,?>)IntegrationWire.publicResponse("id","list_devices",IntegrationWire.success("id",IntegrationWire.object("devices",List.of(peer)))).get("result");
        Map<?,?> item=(Map<?,?>)((List<?>)list.get("devices")).get(0);
        assertEquals(false,((Map<?,?>)item.get("capabilities")).get("openUrlIntentV1"));
        assertEquals(true,((Map<?,?>)item.get("capabilities")).get("sendLinkV1"));
        Map<?,?> status=(Map<?,?>)IntegrationWire.publicResponse("id","send_link",IntegrationWire.success("id",IntegrationWire.object("requestId","id","deliveryMode","link","state","sent","url","private-value"))).get("result");
        assertEquals("link",status.get("deliveryMode"));assertEquals("sent",status.get("state"));assertFalse(status.containsKey("url"));
    }
    @Test public void duplicateArrivalsDuringDispatchJoinOneOperation() throws Exception {
        IntegrationUrlRequests requests=new IntegrationUrlRequests(context,()->{});FocusActivity activity=Robolectric.buildActivity(FocusActivity.class).setup().get();String id=UUID.randomUUID().toString();List<Map<String,Object>> replies=new ArrayList<>();
        requests.receive(url(id,120000),activity,replies::add);requests.receive(url(id,120000),activity,replies::add);
        await(()->replies.size()==2);assertEquals("launch_accepted",replies.get(0).get("state"));assertEquals(replies.get(0).get("resultId"),replies.get(1).get("resultId"));
        assertNotNull(Shadows.shadowOf(activity).getNextStartedActivity());assertNull(Shadows.shadowOf(activity).getNextStartedActivity());requests.worker.shutdown();
    }
    @Test public void coldUncertainDispatchRequiresTapInsteadOfReopening() throws Exception {
        Shadows.shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.POST_NOTIFICATIONS);
        IntegrationUrlRequests requests=new IntegrationUrlRequests(context,()->{});String id=UUID.randomUUID().toString();Map<String,Object> request=url(id,120000);
        Map<String,Object> record=new java.util.LinkedHashMap<>(request);record.put("state","dispatching");record.put("token",UUID.randomUUID().toString());record.put("expiresMs",System.currentTimeMillis()+120000);
        requests.preferences.edit().putString("request:"+IntegrationUrlRequests.key("phone",id),IntegrationWire.encode(record)).commit();
        FocusActivity activity=Robolectric.buildActivity(FocusActivity.class).setup().get();assertEquals("needs_tap",receive(requests,request,activity).get("state"));assertNull(Shadows.shadowOf(activity).getNextStartedActivity());requests.worker.shutdown();
    }
    private android.view.View findText(android.view.View view,String text) {
        if(view instanceof android.widget.TextView && text.contentEquals(((android.widget.TextView)view).getText())) return view;
        if(view instanceof android.view.ViewGroup) for(int i=0;i<((android.view.ViewGroup)view).getChildCount();i++) {android.view.View match=findText(((android.view.ViewGroup)view).getChildAt(i),text);if(match!=null)return match;}
        return null;
    }
    @Test @org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
    public void nativeConsentRendersScopesAndOnlyExplicitApprovalGrants() throws Exception {
        IntegrationAssociations store=new IntegrationAssociations(context);PendingIntent consent=store.consent(store.caller(CHRONA_UID));
        IntegrationAssociationActivity activity=Robolectric.buildActivity(IntegrationAssociationActivity.class,Shadows.shadowOf(consent).getSavedIntent()).setup().get();
        android.view.View root=activity.findViewById(android.R.id.content);assertNotNull("consent state="+activity.isFinishing()+" pending="+store.pending(activity.getIntent().getData().getLastPathSegment())+" title="+activity.getTitle(),findText(root,"读取本组设备"));assertNotNull(findText(root,"发送所选网页"));assertFalse(store.authorized(store.caller(CHRONA_UID)));
        root.measure(android.view.View.MeasureSpec.makeMeasureSpec(420,android.view.View.MeasureSpec.EXACTLY),android.view.View.MeasureSpec.makeMeasureSpec(820,android.view.View.MeasureSpec.EXACTLY));root.layout(0,0,420,820);
        String directory=System.getenv("GLOBALSEND_TEST_ARTIFACTS");
        if(directory!=null) {
            android.graphics.Bitmap image=android.graphics.Bitmap.createBitmap(420,820,android.graphics.Bitmap.Config.ARGB_8888);root.draw(new android.graphics.Canvas(image));
            try(java.io.FileOutputStream output=new java.io.FileOutputStream(new java.io.File(directory,"integration-consent-preview.jpg"))) {image.compress(android.graphics.Bitmap.CompressFormat.JPEG,72,output);}
        }
        findText(root,"允许").performClick();assertTrue(activity.isFinishing());assertTrue(store.authorized(store.caller(CHRONA_UID)));
    }
}
