package dev.globalsend.globalsend;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.net.Uri;
import android.os.Build;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Map;
import org.json.JSONObject;

/** Local association is independent of the GlobalSend account/group credential. */
final class IntegrationAssociations {
    static final String CHRONA="com.donglan.chrona";
    private static final long CONSENT_LIFETIME=5*60*1000L;
    final Context context;
    final SharedPreferences preferences;
    IntegrationAssociations(Context context) {
        this.context=context.getApplicationContext();
        preferences=this.context.getSharedPreferences("integration-associations",Context.MODE_PRIVATE);
    }
    static final class Caller {
        final String packageName,signature,label;
        final int uid;
        final long installedAt;
        Caller(String packageName,String signature,String label,int uid,long installedAt) {
            this.packageName=packageName;this.signature=signature;this.label=label;this.uid=uid;this.installedAt=installedAt;
        }
        Map<String,Object> value() { return IntegrationWire.object("package",packageName,"signature",signature,"label",label,"uid",uid,"installedAt",installedAt); }
        boolean matches(JSONObject value) { return packageName.equals(value.optString("package")) && signature.equals(value.optString("signature")) && uid==value.optInt("uid",-1) && installedAt==value.optLong("installedAt",-1); }
    }
    Caller caller(int uid) {
        if(uid<0) return null;
        PackageManager pm=context.getPackageManager();
        String[] packages=pm.getPackagesForUid(uid);
        // A shared UID is not an unambiguous app identity, even with a known debug key.
        if(packages==null || packages.length!=1 || !CHRONA.equals(packages[0])) return null;
        try {
            PackageInfo info=pm.getPackageInfo(CHRONA,Build.VERSION.SDK_INT>=28 ? PackageManager.GET_SIGNING_CERTIFICATES : PackageManager.GET_SIGNATURES);
            ApplicationInfo app=info.applicationInfo;
            if(app==null || app.uid!=uid) return null;
            Signature[] signers=Build.VERSION.SDK_INT>=28 && info.signingInfo!=null ? info.signingInfo.getApkContentsSigners() : info.signatures;
            if(signers==null || signers.length==0) return null;
            ArrayList<String> fingerprints=new ArrayList<>();
            // Functional installed-caller identity, not an artifact integrity pass.
            for(Signature signer:signers) {
                byte[] digest=MessageDigest.getInstance("SHA-256").digest(signer.toByteArray());
                StringBuilder hex=new StringBuilder();for(byte value:digest) hex.append(String.format(java.util.Locale.ROOT,"%02x",value&255));
                fingerprints.add(hex.toString());
            }
            Collections.sort(fingerprints);
            return new Caller(CHRONA,String.join(",",fingerprints),pm.getApplicationLabel(app).toString(),uid,info.firstInstallTime);
        } catch (PackageManager.NameNotFoundException | java.security.NoSuchAlgorithmException unavailable) { return null; }
    }
    boolean authorized(Caller caller) {
        if(caller==null) return false;
        JSONObject grant=record("grant");
        Caller current=caller(caller.uid);
        return grant!=null && caller.matches(grant) && current!=null && current.matches(grant);
    }
    JSONObject record(String key) {
        try { String text=preferences.getString(key,null);return text==null?null:new JSONObject(text); }
        catch(org.json.JSONException malformed) { return null; }
    }
    PendingIntent consent(Caller caller) {
        long now=System.currentTimeMillis();
        SharedPreferences.Editor edit=preferences.edit();
        for(String key:preferences.getAll().keySet()) if(key.startsWith("pending:")) {
            JSONObject pending=record(key);
            if(pending==null || pending.optLong("expiresAt")<=now) edit.remove(key);
        }
        String token=java.util.UUID.randomUUID().toString();
        Map<String,Object> pending=caller.value();pending.put("expiresAt",now+CONSENT_LIFETIME);
        if(!edit.putString("pending:"+token,IntegrationWire.encode(pending)).commit()) throw new IllegalStateException("无法保存关联请求");
        Intent intent=new Intent(context,IntegrationAssociationActivity.class)
            .setData(new Uri.Builder().scheme("globalsend-integration").authority("associate").appendPath(token).build());
        return PendingIntent.getActivity(context,0,intent,PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_ONE_SHOT|PendingIntent.FLAG_CANCEL_CURRENT);
    }
    Caller pending(String token) {
        JSONObject value=record("pending:"+token);
        if(value==null || value.optLong("expiresAt")<=System.currentTimeMillis()) return null;
        Caller current=caller(value.optInt("uid",-1));
        return current!=null && current.matches(value)?current:null;
    }
    boolean approve(String token) {
        Caller caller=pending(token);
        if(caller==null) return false;
        return preferences.edit().putString("grant",IntegrationWire.encode(caller.value())).remove("pending:"+token).commit();
    }
    void reject(String token) { preferences.edit().remove("pending:"+token).apply(); }
    void revoke() {
        SharedPreferences.Editor edit=preferences.edit().remove("grant");
        for(String key:preferences.getAll().keySet()) if(key.startsWith("pending:")) edit.remove(key);
        edit.commit();
    }
}
