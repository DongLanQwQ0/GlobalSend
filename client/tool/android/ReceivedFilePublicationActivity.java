package dev.globalsend.globalsend;

import android.app.Activity;
import android.content.Intent;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.provider.DocumentsContract;
import android.provider.MediaStore;
import android.widget.TextView;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONObject;

/** Real Android provider/picker acceptance of the production publication class; synthetic files only. */
public final class ReceivedFilePublicationActivity extends Activity {
    private final Handler main = new Handler();
    private final Map<String,byte[]> bytes = new LinkedHashMap<>();
    private final JSONObject result = new JSONObject();
    private File folder;
    private int waiting;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        TextView view = new TextView(this); view.setText("GlobalSend file publication acceptance"); setContentView(view);
        new Thread(() -> { try { run(); } catch (Exception error) { fail(error); } }, "publication-fixture").start();
    }

    private void run() throws Exception {
        String received = getIntent().getStringExtra("inspectFolder");
        if (received != null) {
            folder = new File(received).getCanonicalFile();
            File allowed = new File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),"GlobalSend-publication77-receive").getCanonicalFile();
            if(!folder.equals(allowed))throw new IllegalArgumentException("Only the synthetic receive folder may be inspected");
            for(File file:folder.listFiles())if(file.isFile()&&!file.getName().endsWith(".part"))bytes.put(file.getName(),Files.readAllBytes(file.toPath()));
            if(bytes.isEmpty())throw new IllegalStateException("No received fixture file");
            result.put("scope","Actual production Flutter receiver result: inspect only, no scanner or move in this check");
            result.put("folder",folder.getPath());finishPublication();return;
        }
        folder = new File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                "GlobalSend-publication77-" + System.currentTimeMillis());
        if (!folder.mkdirs()) throw new IllegalStateException("Cannot create fixture directory");
        result.put("scope", "Production publisher and real Android 36 MediaStore/Downloads/system picker; not physical OEM acceptance");
        result.put("folder", folder.getPath());
        bytes.put("GS77-正文.txt", "GlobalSend 接收文件无需移动即可选择".getBytes(StandardCharsets.UTF_8));
        bytes.put("GS77-报告.pdf", "%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\n%%EOF".getBytes(StandardCharsets.US_ASCII));
        Bitmap image = Bitmap.createBitmap(32,32,Bitmap.Config.ARGB_8888); image.eraseColor(Color.CYAN);
        for (var format : new Bitmap.CompressFormat[]{Bitmap.CompressFormat.JPEG,Bitmap.CompressFormat.PNG}) {
            ByteArrayOutputStream stream = new ByteArrayOutputStream(); image.compress(format,90,stream);
            bytes.put("GS77-图片." + (format == Bitmap.CompressFormat.JPEG ? "jpg" : "png"),stream.toByteArray());
        }
        image.recycle();
        for (var item : bytes.entrySet()) {
            File partial = new File(folder,item.getKey()+".part"), complete = new File(folder,item.getKey());
            Files.write(partial.toPath(),item.getValue()); Files.move(partial.toPath(),complete.toPath());
        }
        result.put("before",indexed(MediaStore.Files.getContentUri("external")));
        waiting=bytes.size();
        for (String name : bytes.keySet()) {
            if (!ReceivedFilePublication.publish(this,new File(folder,name).getPath(),(path,uri) -> main.post(() -> {
                try {
                    if(uri==null)throw new IllegalStateException("Scanner did not publish " + path);
                    if(--waiting==0)finishPublication();
                } catch(Exception error){fail(error);}
            }))) throw new IllegalStateException("Publisher skipped shared fixture");
        }
    }

    private JSONArray indexed(Uri collection) throws Exception {
        JSONArray rows=new JSONArray();
        try(Cursor cursor=getContentResolver().query(collection,
                new String[]{"_display_name","mime_type","_size","_data"},"relative_path=?",
                new String[]{"Download/"+folder.getName()+"/"},null)) {
            if(cursor==null)throw new IllegalStateException("No provider cursor");
            while(cursor.moveToNext()) {
                JSONObject item=new JSONObject(); item.put("name",cursor.getString(0));item.put("mime",cursor.getString(1));
                item.put("size",cursor.getLong(2));item.put("path",cursor.getString(3));rows.put(item);
            }
        }
        return rows;
    }

    private void finishPublication() throws Exception {
        JSONArray files=indexed(MediaStore.Files.getContentUri("external")),downloads=indexed(MediaStore.Downloads.EXTERNAL_CONTENT_URI);
        if(files.length()!=bytes.size()||downloads.length()!=bytes.size())throw new IllegalStateException("Missing indexed files: "+files+" downloads="+downloads);
        for(var item:bytes.entrySet())if(!Arrays.equals(item.getValue(),Files.readAllBytes(new File(folder,item.getKey()).toPath())))
            throw new IllegalStateException("Bytes changed: "+item.getKey());
        result.put("files",files);result.put("downloads",downloads);result.put("bytesUnchanged",true);result.put("published",true);save();
        long parent;
        try(Cursor cursor=getContentResolver().query(MediaStore.Files.getContentUri("external"),new String[]{"_id"},"_data=?",new String[]{folder.getPath()},null)) {
            if(cursor==null||!cursor.moveToFirst())throw new IllegalStateException("Parent directory not indexed");
            parent=cursor.getLong(0);
        }
        Intent picker=new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE);
        picker.putExtra(DocumentsContract.EXTRA_INITIAL_URI,DocumentsContract.buildDocumentUri("com.android.providers.downloads.documents","msd:"+parent));
        startActivityForResult(picker,77);
    }

    @Override protected void onActivityResult(int request,int code,Intent data) {
        super.onActivityResult(request,code,data);
        if(request!=77||code!=RESULT_OK||data==null)return;
        try(var input=getContentResolver().openInputStream(data.getData())) {
            byte[] actual=input.readAllBytes();boolean match=bytes.values().stream().anyMatch(expected->Arrays.equals(expected,actual));
            result.put("selectedReadableAndMatches",match);result.put("selectedUri",data.getData().toString());save();
        } catch(Exception error){fail(error);}
    }
    private void save() throws Exception { Files.write(new File(getFilesDir(),"publication-result.json").toPath(),result.toString(2).getBytes(StandardCharsets.UTF_8)); }
    private void fail(Exception error) { try {result.put("error",error.toString());save();}catch(Exception ignored){} }
}
