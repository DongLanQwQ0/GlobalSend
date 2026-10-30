package dev.globalsend.globalsend;

import android.app.Activity;
import android.content.ClipData;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.DocumentsContract;
import android.provider.OpenableColumns;
import io.flutter.plugin.common.MethodChannel;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.Supplier;
import org.json.JSONArray;
import org.json.JSONObject;

/** Standard Sharesheet plus a durable, acked inbox for external SEND intents. */
final class FileShareBridge {
    private final Context context;
    private final MethodChannel channel;
    private final Supplier<Activity> host;
    private final Handler main=new Handler(Looper.getMainLooper());
    private final ExecutorService importer=Executors.newSingleThreadExecutor();
    private File inbox(){return new File(context.getFilesDir(),"shared-inbox");}
    FileShareBridge(Context context,MethodChannel channel,Supplier<Activity> host){
        this.context=context.getApplicationContext();this.channel=channel;this.host=host;
        channel.setMethodCallHandler((call,result)->{
            try{
                if(call.method.equals("share")){share(call.argument("paths"),call.argument("text"));result.success(null);}
                else if(call.method.equals("pending")){importer.execute(()->{try{List<Map<String,Object>> value=pending();main.post(()->result.success(value));}catch(Exception error){main.post(()->result.error("SHARE_INBOX",error.getMessage(),null));}});}
                else if(call.method.equals("ack")){ack(call.argument("batchId"));result.success(null);}
                else result.notImplemented();
            }catch(Exception error){result.error("SHARE_FAILED",error.getMessage(),null);}
        });
    }
    List<Map<String,Object>> pending() throws Exception {
        List<Map<String,Object>> output=new ArrayList<>();File[] manifests=inbox().listFiles((dir,name)->name.endsWith(".json"));if(manifests==null)return output;
        java.util.Arrays.sort(manifests,java.util.Comparator.comparingLong(File::lastModified));
        for(File manifest:manifests){JSONObject value=new JSONObject(readManifest(manifest));Map<String,Object> batch=new java.util.HashMap<>();batch.put("batchId",value.getString("batchId"));for(String key:new String[]{"paths","texts","temporaryPaths"}){JSONArray list=value.getJSONArray(key);List<String> strings=new ArrayList<>();for(int i=0;i<list.length();i++)strings.add(list.getString(i));batch.put(key,strings);}if(value.has("error"))batch.put("error",value.getString("error"));output.add(batch);}
        return output;
    }
    void ack(String id) throws Exception {UUID.fromString(id);File manifest=new File(inbox(),id+".json");if(manifest.exists()&&!manifest.delete())throw new IllegalStateException("无法确认分享内容");}
    private static String readManifest(File file)throws Exception{try(InputStream input=new java.io.FileInputStream(file);java.io.ByteArrayOutputStream output=new java.io.ByteArrayOutputStream()){byte[] bytes=new byte[8192];int count;while((count=input.read(bytes))!=-1)output.write(bytes,0,count);return new String(output.toByteArray(),StandardCharsets.UTF_8);}}
    boolean handleIntent(Intent intent){
        if(intent==null || !(Intent.ACTION_SEND.equals(intent.getAction()) || Intent.ACTION_SEND_MULTIPLE.equals(intent.getAction())))return false;
        final List<Uri> uris=new ArrayList<>();final LinkedHashSet<String> texts=new LinkedHashSet<>();
        ClipData clip=intent.getClipData();if(clip!=null)for(int i=0;i<clip.getItemCount();i++){ClipData.Item item=clip.getItemAt(i);if(item.getUri()!=null)uris.add(item.getUri());else if(item.getText()!=null)texts.add(item.getText().toString());}
        if(Intent.ACTION_SEND.equals(intent.getAction())){Uri uri=Build.VERSION.SDK_INT>=33?intent.getParcelableExtra(Intent.EXTRA_STREAM,Uri.class):intent.getParcelableExtra(Intent.EXTRA_STREAM);if(uri!=null)uris.add(uri);}
        else {ArrayList<Uri> many=Build.VERSION.SDK_INT>=33?intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM,Uri.class):intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM);if(many!=null)uris.addAll(many);}
        Object extra=intent.getExtras()==null?null:intent.getExtras().get(Intent.EXTRA_TEXT);
        if(extra instanceof CharSequence)texts.add(extra.toString());
        else if(extra instanceof Iterable<?>)for(Object item:(Iterable<?>)extra)if(item instanceof CharSequence)texts.add(item.toString());
        if(texts.isEmpty()&&intent.getStringExtra(Intent.EXTRA_HTML_TEXT)!=null)texts.add(intent.getStringExtra(Intent.EXTRA_HTML_TEXT));
        final List<Uri> distinct=new ArrayList<>(new LinkedHashSet<>(uris));
        intent.setAction(null); // Activity recreation/resume cannot enqueue the same Intent twice.
        importer.execute(()->importBatch(distinct,new ArrayList<>(texts)));
        return true;
    }
    private void importBatch(List<Uri> uris,List<String> texts){
        String id=UUID.randomUUID().toString();File root=new File(inbox(),id);List<String> paths=new ArrayList<>();String failure=null;
        try{
            if(!root.mkdirs()&&!root.isDirectory())throw new IllegalStateException("无法创建分享接收目录");
            int index=0;
            for(Uri uri:uris){
                File part=new File(root,String.valueOf(index++));
                try{
                    if(!part.mkdir())throw new IllegalStateException("无法保存分享文件");
                    paths.add(importItem(uri,part).getPath());
                }catch(Exception error){removePartial(part);failure="部分分享内容未能导入："+error.getMessage();}
            }
        }catch(Exception error){failure="部分分享内容未能导入："+error.getMessage();}
        try{
            JSONObject value=new JSONObject();value.put("batchId",id);value.put("paths",new JSONArray(paths));value.put("texts",new JSONArray(texts));value.put("temporaryPaths",new JSONArray(paths));if(failure!=null)value.put("error",failure);
            File temporary=new File(inbox(),id+".tmp");try(FileOutputStream output=new FileOutputStream(temporary)){output.write(value.toString().getBytes(StandardCharsets.UTF_8));output.getFD().sync();}
            if(!temporary.renameTo(new File(inbox(),id+".json")))throw new IllegalStateException("无法保存分享记录");
            main.post(()->channel.invokeMethod("pendingChanged",null));
        }catch(Exception error){main.post(()->channel.invokeMethod("importError","分享未能保存："+error.getMessage()));}
    }
    private File importItem(Uri uri,File part)throws Exception{
        boolean treeRoot="content".equals(uri.getScheme())&&DocumentsContract.isTreeUri(uri)&&uri.getPathSegments().size()==2;
        if("content".equals(uri.getScheme())&&(treeRoot||DocumentsContract.Document.MIME_TYPE_DIR.equals(context.getContentResolver().getType(uri)))){
            List<Map<String,Object>> entries=SendFolderEntries.read(context,uri);
            File directory=null;String parent=part.getCanonicalPath()+File.separator;
            for(Map<String,Object> entry:entries){
                File target=new File(part,(String)entry.get("relativePath"));
                if(!target.getCanonicalPath().startsWith(parent))throw new IllegalStateException("无法导入文件夹名称");
                if(directory==null)directory=target;
                if("directory".equals(entry.get("entryKind"))){if(!target.mkdirs()&&!target.isDirectory())throw new IllegalStateException("无法创建分享文件夹");}
                else copyBytes(Uri.parse((String)entry.get("location")),target);
            }
            if(directory==null)throw new IllegalStateException("无法读取分享文件夹");
            return directory;
        }
        String name="shared-file";if("file".equals(uri.getScheme()))name=new File(uri.getPath()).getName();
        else try(Cursor cursor=context.getContentResolver().query(uri,new String[]{OpenableColumns.DISPLAY_NAME},null,null,null)){if(cursor!=null&&cursor.moveToFirst()&&cursor.getString(0)!=null)name=cursor.getString(0);}
        if(MediaFileName.needsSuffix(name))name=MediaFileName.withType(name,context.getContentResolver().getType(uri));
        name=name.replaceAll("[\\\\/\\x00-\\x1f]","_");if(name.isEmpty()||name.equals(".")||name.equals(".."))name="shared-file";
        File target=new File(part,name);copyBytes(uri,target);return target;
    }
    private void copyBytes(Uri uri,File target)throws Exception{
        boolean copied=false;
        try(InputStream input="file".equals(uri.getScheme())?new java.io.FileInputStream(new File(uri.getPath())):context.getContentResolver().openInputStream(uri);FileOutputStream output=new FileOutputStream(target)){
            if(input==null)throw new IllegalStateException("来源未授予文件读取权限");byte[] bytes=new byte[65536];int count;
            while((count=input.read(bytes))!=-1){if(Thread.currentThread().isInterrupted())throw new InterruptedException("已停止导入");output.write(bytes,0,count);}output.getFD().sync();copied=true;
        }finally{if(!copied)target.delete();}
    }
    private static void removePartial(File item){File[] children=item.listFiles();if(children!=null)for(File child:children)removePartial(child);item.delete();}
    void share(List<String> paths,String text) throws Exception {
        List<String> values=paths==null?java.util.Collections.emptyList():paths;ArrayList<Uri> uris=new ArrayList<>();String mime=null;
        for(String path:values){String readable=ReceiveDirectory.readableLocation(context,path);Uri uri;if(readable.startsWith("content://"))uri=Uri.parse(readable);else uri=DockShareProvider.registerForShare(context,new File(readable),new File(path).getName());uris.add(uri);String next=context.getContentResolver().getType(uri);if(next==null)next="application/octet-stream";if(mime==null)mime=next;else if(!mime.equals(next))mime=mime.split("/")[0].equals(next.split("/")[0])?mime.split("/")[0]+"/*":"*/*";}
        if(uris.isEmpty()&&(text==null||text.isEmpty()))return;
        Intent intent=new Intent(uris.size()>1?Intent.ACTION_SEND_MULTIPLE:Intent.ACTION_SEND).setType(mime==null?"text/plain":mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        if(text!=null&&!text.isEmpty())intent.putExtra(Intent.EXTRA_TEXT,text);
        if(!uris.isEmpty()){
            if(uris.size()==1)intent.putExtra(Intent.EXTRA_STREAM,uris.get(0));else intent.putParcelableArrayListExtra(Intent.EXTRA_STREAM,uris);
            ClipData clip=ClipData.newUri(context.getContentResolver(),"GlobalSend",uris.get(0));for(int i=1;i<uris.size();i++)clip.addItem(new ClipData.Item(uris.get(i)));if(text!=null&&!text.isEmpty())clip.addItem(new ClipData.Item(text));intent.setClipData(clip);
        }else intent.setClipData(ClipData.newPlainText("GlobalSend",text));
        Activity activity=host.get();if(activity==null||activity.isFinishing())throw new IllegalStateException("请回到应用进行分享");
        activity.startActivity(Intent.createChooser(intent,"分享"));
    }
    void dispose(){importer.shutdownNow();}
}
