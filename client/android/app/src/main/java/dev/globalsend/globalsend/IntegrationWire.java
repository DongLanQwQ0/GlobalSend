package dev.globalsend.globalsend;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.json.JSONArray;
import org.json.JSONObject;

/** Small value-only ABI; credentials and controller objects never cross it. */
final class IntegrationWire {
    static boolean uuid(String value) {
        try { return value != null && value.length() == 36 && UUID.fromString(value).toString().equalsIgnoreCase(value); }
        catch (IllegalArgumentException invalid) { return false; }
    }
    static Map<String,Object> object(Object... fields) {
        Map<String,Object> value = new LinkedHashMap<>();
        for (int i=0;i<fields.length;i+=2) value.put((String)fields[i],fields[i+1]);
        return value;
    }
    static Map<String,Object> success(String id,Map<String,Object> result) {
        return object("v",1,"requestId",id,"ok",true,"result",result);
    }
    static Map<String,Object> error(String id,String code,String message,boolean retryable) {
        return object("v",1,"requestId",id,"ok",false,"error",object("code",code,"message",message,"retryable",retryable));
    }
    static Map<String,Object> json(JSONObject value) {
        Map<String,Object> result = new LinkedHashMap<>();
        java.util.Iterator<String> keys=value.keys();
        while(keys.hasNext()) { String key=keys.next(); result.put(key,plain(value.opt(key))); }
        return result;
    }
    private static Object plain(Object value) {
        if (value==JSONObject.NULL) return null;
        if (value instanceof JSONObject) return json((JSONObject)value);
        if (value instanceof JSONArray) {
            List<Object> array=new ArrayList<>();
            for(int i=0;i<((JSONArray)value).length();i++) array.add(plain(((JSONArray)value).opt(i)));
            return array;
        }
        return value;
    }
    static String encode(Map<String,Object> value) { return new JSONObject(value).toString(); }
    static Map<String,Object> subset(Map<?,?> input,String... keys) {
        Map<String,Object> result=new LinkedHashMap<>();
        for(String key:keys) if(input.containsKey(key)) result.put(key,input.get(key));
        return result;
    }
    /** Explicit allowlist of public fields, including nested errors and capabilities. */
    static Map<String,Object> publicResponse(String id,String method,Object raw) {
        if (!(raw instanceof Map)) return error(id,"not_connected","GlobalSend 尚未就绪",true);
        Map<?,?> envelope=(Map<?,?>)raw;
        if (!Boolean.TRUE.equals(envelope.get("ok"))) {
            Object detail=envelope.get("error");
            if (!(detail instanceof Map)) return error(id,"not_connected","GlobalSend 暂时不可用",true);
            Map<?,?> failure=(Map<?,?>)detail;
            return error(id,failure.get("code") instanceof String ? (String)failure.get("code") : "not_connected",
                failure.get("message") instanceof String ? (String)failure.get("message") : "操作未完成",
                Boolean.TRUE.equals(failure.get("retryable")));
        }
        if (!(envelope.get("result") instanceof Map)) return error(id,"not_connected","GlobalSend 尚未就绪",true);
        Map<?,?> body=(Map<?,?>)envelope.get("result"); Map<String,Object> result;
        if ("hello".equals(method)) {
            result=subset(body,"connected");
        } else if ("list_devices".equals(method)) {
            List<Map<String,Object>> devices=new ArrayList<>();
            Object list=body.get("devices");
            if(list instanceof List) for(Object value:(List<?>)list) if(value instanceof Map) {
                Map<?,?> item=(Map<?,?>)value;
                Map<String,Object> device=subset(item,"deviceId","name","platform","online","sendable");
                Object capabilities=item.get("capabilities");
                device.put("capabilities",object(
                    "openUrlIntentV1",capabilities instanceof Map && Boolean.TRUE.equals(((Map<?,?>)capabilities).get("openUrlIntentV1")),
                    "sendLinkV1",capabilities instanceof Map && Boolean.TRUE.equals(((Map<?,?>)capabilities).get("sendLinkV1"))));
                devices.add(device);
            }
            result=object("devices",devices,"updatedAt",body.get("updatedAt"));
        } else {
            result=subset(body,"requestId","targetDeviceId","state","createdAt","expiresAt","updatedAt","deliveryMode");
            if(body.get("error") instanceof Map) result.put("error",subset((Map<?,?>)body.get("error"),"code","message"));
        }
        return success(id,result);
    }
}
