package dev.globalsend.globalsend;

import android.content.Context;
import android.net.Uri;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.ParcelFileDescriptor;
import android.os.ProxyFileDescriptorCallback;
import android.os.storage.StorageManager;
import android.system.ErrnoException;
import android.system.OsConstants;
import android.provider.DocumentsContract;
import java.io.File;
import java.io.FileNotFoundException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Consumer;

/** Data is resolved on a provider worker, never by blocking the activity UI. */
final class RemoteReferenceFiles {
    static final class Part {
        final String path,name;final long size;final boolean directory;
        Part(String path,long size,boolean directory) {
            this.path=path;int slash=path.lastIndexOf('/');name=path.substring(slash+1);this.size=size;this.directory=directory;
        }
    }
    static final class Entry {
        final String token=UUID.randomUUID().toString();
        final Map<String,Object> reference;
        final List<Part> parts;
        final CompletableFuture<String> local=new CompletableFuture<>();
        final long created=System.currentTimeMillis();
        boolean requested;
        final java.util.Set<String> grantedPackages=ConcurrentHashMap.newKeySet();
        android.content.Context grantContext;
        Uri grantedTree;
        boolean revoked;
        Entry(Map<String,Object> reference,List<Part> parts){this.reference=reference;this.parts=parts;}
        synchronized CompletableFuture<String> resolve() {
            if(!requested){requested=true;Consumer<Map<String,Object>> listener=resolver;
                if(listener==null)local.completeExceptionally(new FileNotFoundException("接收服务已关闭"));
                else try { listener.accept(Map.of("token",token,"reference",reference)); }
                catch (RuntimeException error) { local.completeExceptionally(error); }
            }
            return local;
        }
        Part part(String path) throws FileNotFoundException {return parts.stream().filter(value->value.path.equals(path)).findFirst().orElseThrow(()->new FileNotFoundException("远程目录项不存在"));}
        synchronized void revokeTreeGrant() {
            revoked=true;
            if(grantContext!=null && grantedTree!=null)grantContext.revokeUriPermission(grantedTree,android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION);
            grantedPackages.clear();grantContext=null;grantedTree=null;
        }
    }
    private static final ConcurrentHashMap<String,Entry> entries=new ConcurrentHashMap<>();
    private static volatile Consumer<Map<String,Object>> resolver;
    private static final HandlerThread ioThread=new HandlerThread("GlobalSend-remote-file-provider");
    static {ioThread.start();}
    private static final Handler io=new Handler(ioThread.getLooper());
    static void listen(Consumer<Map<String,Object>> listener){resolver=listener;}
    static void stop(){resolver=null;for(Entry entry:entries.values()){entry.local.completeExceptionally(new FileNotFoundException("接收服务已关闭"));entry.revokeTreeGrant();}entries.clear();}
    @SuppressWarnings("unchecked")
    static Entry register(Map<String,?> value) throws Exception {
        entries.entrySet().removeIf(row->{Entry entry=row.getValue();boolean expired=System.currentTimeMillis()-entry.created>600000 && (!entry.requested || entry.local.isDone());if(expired)entry.revokeTreeGrant();return expired;});
        Map<String,Object> reference=new HashMap<>();reference.putAll(value);
        String name=String.valueOf(value.get("name"));boolean directory="directory".equals(value.get("kind"));
        Object manifest=value.get("entries");
        if(manifest instanceof String){org.json.JSONArray array=new org.json.JSONArray((String)manifest);List<Map<String,Object>> parsed=new ArrayList<>();
            for(int i=0;i<array.length();i++){org.json.JSONObject item=array.getJSONObject(i);parsed.add(Map.of("relativePath",item.getString("relativePath"),"size",item.optLong("size"),"kind",item.optString("kind","file")));}manifest=parsed;}
        List<Part> parts=new ArrayList<>();
        if(manifest instanceof List)for(Object row:(List<?>)manifest){Map<String,?> item=(Map<String,?>)row;String path=String.valueOf(item.get("relativePath")).replace('\\','/');
            if(path.startsWith("/") || path.isEmpty())throw new IllegalArgumentException("无效目录项");
            for(String segment:path.split("/",-1))if(segment.isEmpty() || segment.equals("..") || segment.equals("."))throw new IllegalArgumentException("无效目录项");
            parts.add(new Part(path,number(item.get("size")),"directory".equals(item.get("kind"))));}
        else if(!directory)parts.add(new Part(name,number(value.get("size")),false));
        else throw new IllegalArgumentException("目录需先取得完整目录清单，不能作为空目录拖出");
        if(parts.isEmpty())throw new IllegalArgumentException("没有可拖动内容");
        Entry entry=new Entry(reference,parts);entries.put(entry.token,entry);return entry;
    }
    private static long number(Object value){return value instanceof Number?((Number)value).longValue():value==null?0:Long.parseLong(value.toString());}
    static Uri uri(Context context,Entry entry){String id=entry.token+":"+entry.parts.get(0).path;
        return DocumentsContract.buildDocumentUriUsingTree(DocumentsContract.buildTreeDocumentUri(context.getPackageName()+".remote-files",id),id);}
    static Entry entry(String id) throws FileNotFoundException {int colon=id.indexOf(':');Entry result=colon<0?null:entries.get(id.substring(0,colon));if(result==null)throw new FileNotFoundException("远程拖放已结束");return result;}
    static String relative(String id) throws FileNotFoundException {int colon=id.indexOf(':');if(colon<0)throw new FileNotFoundException();return id.substring(colon+1);}
    static void complete(String token,List<String> paths,String error) {
        Entry entry=entries.get(token);if(entry==null)return;
        if(error!=null && !error.isEmpty())entry.local.completeExceptionally(new FileNotFoundException(error));
        else if(paths==null || paths.size()!=1)entry.local.completeExceptionally(new FileNotFoundException("未取得完整文件或目录"));
        else entry.local.complete(paths.get(0));
    }
    static ParcelFileDescriptor open(Context context,Entry entry,Part part) throws FileNotFoundException {
        if(part.directory)throw new FileNotFoundException("请读取目录中的文件");
        if(android.os.Build.VERSION.SDK_INT<26) {
            try {
                ParcelFileDescriptor[] pipe=ParcelFileDescriptor.createReliablePipe();
                new Thread(() -> {
                    try(ParcelFileDescriptor source=openResolved(context,entry,part);
                        java.io.InputStream input=new ParcelFileDescriptor.AutoCloseInputStream(source);
                        java.io.OutputStream output=new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])) {
                        byte[] buffer=new byte[65536];int count;
                        while((count=input.read(buffer))!=-1)output.write(buffer,0,count);
                    } catch(Exception error) {try{pipe[1].closeWithError(error.getMessage()==null?"无法拉取文件":error.getMessage());}catch(java.io.IOException ignored){}}
                },"GlobalSend-remote-pipe").start();
                return pipe[0];
            } catch(java.io.IOException error) {throw new FileNotFoundException(error.getMessage());}
        }
        StorageManager storage=context.getSystemService(StorageManager.class);
        try{return storage.openProxyFileDescriptor(ParcelFileDescriptor.MODE_READ_ONLY,reader(context,entry,part),io);}
        catch(java.io.IOException error){throw new FileNotFoundException(error.getMessage());}
    }
    static ProxyFileDescriptorCallback reader(Context context,Entry entry,Part part) {
        return new ProxyFileDescriptorCallback(){
            ParcelFileDescriptor file;
            public long onGetSize(){return part.size;}
            public int onRead(long offset,int size,byte[] data) throws ErrnoException {
                try{
                    if(file==null)file=openResolved(context,entry,part);
                    int count=android.system.Os.pread(file.getFileDescriptor(),data,0,size,offset);return count<0?0:count;
                }catch(Exception error){throw new ErrnoException("remote-file-read",OsConstants.EIO,error);}
            }
            public void onRelease(){if(file!=null)try{file.close();}catch(java.io.IOException ignored){}}
        };
    }
    private static ParcelFileDescriptor openResolved(Context context,Entry entry,Part part) throws Exception {
        String root=entry.resolve().get();String suffix=part.path.contains("/")?part.path.substring(part.path.indexOf('/')+1):"";
        String location=ReceiveDirectory.readableLocation(context,root);
        ParcelFileDescriptor file;
        if(location.startsWith("content://")) {
            Uri document=Uri.parse(location);
            if(!suffix.isEmpty())for(String segment:suffix.split("/")) {
                String id=DocumentsContract.isDocumentUri(context,document)?DocumentsContract.getDocumentId(document):DocumentsContract.getTreeDocumentId(document);
                Uri children=DocumentsContract.buildChildDocumentsUriUsingTree(document,id);Uri next=null;
                try(android.database.Cursor cursor=context.getContentResolver().query(children,new String[]{DocumentsContract.Document.COLUMN_DOCUMENT_ID,DocumentsContract.Document.COLUMN_DISPLAY_NAME},null,null,null)) {
                    if(cursor!=null)while(cursor.moveToNext())if(segment.equals(cursor.getString(1))){next=DocumentsContract.buildDocumentUriUsingTree(document,cursor.getString(0));break;}
                }
                if(next==null)throw new FileNotFoundException("目录中的文件已移除");document=next;
            }
            file=context.getContentResolver().openFileDescriptor(document,"r");
        } else {
            File target=suffix.isEmpty()?new File(location):new File(location,suffix);
            file=ParcelFileDescriptor.open(target,ParcelFileDescriptor.MODE_READ_ONLY);
        }
        if(file==null)throw new FileNotFoundException("无法读取文件");return file;
    }
}
