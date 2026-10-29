package dev.globalsend.shelfacceptance;

import android.app.Activity;
import android.content.ClipData;
import android.graphics.Color;
import android.os.Bundle;
import android.view.DragEvent;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import org.json.JSONObject;

/** A network-free source/target for real OS drags, not a GlobalSend replacement. */
public final class ShelfAcceptanceActivity extends Activity {
    private int sequence = 1, accepted;
    private TextView source, destination;
    private android.widget.CheckBox legacyReader;
    private String marker() { return "GS-shelf-physical:" + sequence; }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout page = new LinearLayout(this);
        page.setOrientation(LinearLayout.VERTICAL);
        page.setPadding(dp(20), dp(24), dp(20), dp(24));
        page.setBackgroundColor(0xfff4f5f4);
        page.setOnApplyWindowInsetsListener((view, insets) -> {
            android.graphics.Insets safe = insets.getInsets(WindowInsets.Type.systemBars());
            view.setPadding(dp(20) + safe.left, dp(24) + safe.top, dp(20) + safe.right, dp(24) + safe.bottom);
            return insets;
        });
        setContentView(page);
        TextView heading = label("暂存坞 · 系统拖放验收", 22);
        page.addView(heading, new LinearLayout.LayoutParams(-1, dp(52)));
        source = label(marker(), 18);
        source.setContentDescription("fixture-source");
        source.setGravity(Gravity.CENTER);
        source.setBackgroundColor(0xffdde9e5);
        source.setOnLongClickListener(view -> view.startDragAndDrop(
            ClipData.newPlainText("GlobalSend synthetic shelf fixture", marker()),
            new View.DragShadowBuilder(view), null, View.DRAG_FLAG_GLOBAL));
        page.addView(source, new LinearLayout.LayoutParams(-1, dp(100)));
        Button next = new Button(this);
        next.setText("下一条测试文本");
        next.setOnClickListener(view -> { sequence++; source.setText(marker()); });
        page.addView(next, new LinearLayout.LayoutParams(-1, dp(56)));
        Button image=new Button(this);image.setText("长按拖出测试图片");image.setContentDescription("fixture-image-source");
        image.setOnLongClickListener(view -> view.startDragAndDrop(ClipData.newUri(getContentResolver(),"GS synthetic image",
            android.net.Uri.parse("content://dev.globalsend.shelfacceptance.probe/probe.png")),new View.DragShadowBuilder(view),null,
            View.DRAG_FLAG_GLOBAL | View.DRAG_FLAG_GLOBAL_URI_READ));
        page.addView(image,new LinearLayout.LayoutParams(-1,dp(72)));
        Button cleanup=new Button(this);cleanup.setText("移除本工具创建的相册测试图");
        cleanup.setOnClickListener(view -> removeSyntheticGalleryImage());
        page.addView(cleanup,new LinearLayout.LayoutParams(-1,dp(48)));
        legacyReader=new android.widget.CheckBox(this);legacyReader.setText("按真实路径读取（微信兼容）");
        legacyReader.setChecked(getIntent().getBooleanExtra("legacyReader",false));
        page.addView(legacyReader,new LinearLayout.LayoutParams(-1,dp(48)));
        destination = label("将测试项拖到这里\n接受明确投放的文件，仅检查读取授权和格式", 18);
        destination.setContentDescription("fixture-target");
        destination.setGravity(Gravity.CENTER);
        destination.setBackgroundColor(0xffe6e8ec);
        destination.setOnDragListener((view, event) -> {
            if (event.getAction() == DragEvent.ACTION_DRAG_STARTED) return true;
            if (event.getAction() != DragEvent.ACTION_DROP) return true;
            ClipData clip = event.getClipData();
            if (clip == null || clip.getItemCount() == 0) return false;
            recordClip(clip);
            android.view.DragAndDropPermissions permission=requestDragAndDropPermissions(event);
            int fileItems=0;
            try {
                for (int i = 0; i < clip.getItemCount(); i++) {
                    android.net.Uri uri=clip.getItemAt(i).getUri();
                    if(uri!=null) {
                        // Exercise the target-side grant and actual provider FD,
                        // without saving the URI, filename, or user file content.
                        java.io.InputStream stream;
                        if(legacyReader.isChecked()) {
                            try(android.database.Cursor cursor=getContentResolver().query(uri,new String[]{"_data"},null,null,null)) {
                                if(cursor==null || !cursor.moveToFirst() || cursor.isNull(cursor.getColumnIndexOrThrow("_data")))
                                    throw new java.io.FileNotFoundException("No legacy path");
                                stream=new java.io.FileInputStream(cursor.getString(cursor.getColumnIndexOrThrow("_data")));
                            }
                        } else stream=getContentResolver().openInputStream(uri);
                        try(java.io.InputStream input=stream) {
                            if(input==null)throw new java.io.IOException("No stream");
                            input.read(); fileItems++;
                        }
                    } else {
                        CharSequence text = clip.getItemAt(i).getText();
                        if (text == null || !text.toString().startsWith("GS-shelf-physical:")) return false;
                    }
                }
            } catch(Exception failure) {
                destination.setText("文件读取失败："+failure.getClass().getSimpleName());
                try {
                    JSONObject result=new JSONObject();
                    result.put("fileGrantObtained",permission!=null);result.put("readable",false);
                    result.put("errorType",failure.getClass().getSimpleName());
                    result.put("readMode",legacyReader.isChecked()?"legacy-path":"content-stream");
                    Files.write(new File(getFilesDir(),"uri-outcome.json").toPath(),result.toString().getBytes(StandardCharsets.UTF_8));
                } catch(Exception writeFailed) { throw new IllegalStateException(writeFailed); }
                return false;
            } finally { if(permission!=null)permission.release(); }
            accepted++;
            destination.setText("系统已接收 " + accepted + " 次测试投放");
            try {
                JSONObject result = new JSONObject();
                result.put("acceptedDrops", accepted);
                result.put("items", clip.getItemCount());
                result.put("receivedAtMillis", System.currentTimeMillis());
                result.put("fileItems",fileItems);
                result.put("fileGrantObtained",permission!=null);
                result.put("readable",true);
                result.put("readMode",legacyReader.isChecked()?"legacy-path":"content-stream");
                result.put("syntheticOnly",fileItems==0);
                Files.write(new File(getFilesDir(), "outcome.json").toPath(), result.toString().getBytes(StandardCharsets.UTF_8));
            } catch (Exception failed) { throw new IllegalStateException(failed); }
            return true;
        });
        LinearLayout.LayoutParams targetSize = new LinearLayout.LayoutParams(-1, dp(220));
        targetSize.topMargin = dp(20);
        page.addView(destination, targetSize);
        page.requestApplyInsets();
        applyRotation(getIntent());
        if("gallery".equals(getIntent().getStringExtra("probe")))openSyntheticGalleryImage();
    }
    @Override protected void onNewIntent(android.content.Intent intent) {
        super.onNewIntent(intent);setIntent(intent);applyRotation(intent);
        if(intent.hasExtra("legacyReader"))legacyReader.setChecked(intent.getBooleanExtra("legacyReader",false));
        if("gallery".equals(intent.getStringExtra("probe")))openSyntheticGalleryImage();
    }
    private void recordClip(ClipData clip) {
        try {
            JSONObject result=new JSONObject();org.json.JSONArray types=new org.json.JSONArray(),items=new org.json.JSONArray();
            for(int i=0;i<clip.getDescription().getMimeTypeCount();i++)types.put(clip.getDescription().getMimeType(i));
            result.put("mimeTypes",types);result.put("count",clip.getItemCount());
            android.os.PersistableBundle extras=clip.getDescription().getExtras();JSONObject fields=new JSONObject();
            if(extras!=null)for(String key:extras.keySet()) {
                Object value=extras.get(key);
                if(value instanceof int[]) {org.json.JSONArray flags=new org.json.JSONArray();for(int flag:(int[])value)flags.put(flag);fields.put(key,flags);}
                else fields.put(key,value instanceof Number || value instanceof Boolean?value:value==null?"null":value.getClass().getSimpleName());
            }
            result.put("extraFields",fields);String kind="other";
            for(int i=0;i<clip.getItemCount();i++) {
                ClipData.Item item=clip.getItemAt(i);JSONObject record=new JSONObject();android.net.Uri uri=item.getUri();
                String authority=uri==null || uri.getAuthority()==null?"":uri.getAuthority();
                record.put("hasText",item.getText()!=null);record.put("authority",authority);
                record.put("scheme",uri==null?"":uri.getScheme());
                if(uri!=null && "dev.globalsend.globalsend.dock-files".equals(uri.getAuthority()))kind="globalsend";
                if(uri!=null && ("media".equals(authority) || authority.contains("gallery")))kind="gallery";
                android.content.Intent intent=item.getIntent();
                if(intent!=null) {
                    record.put("intentAction",intent.getAction());record.put("intentType",intent.getType());record.put("intentFlags",intent.getFlags());
                    record.put("hasStreamExtra",intent.hasExtra(android.content.Intent.EXTRA_STREAM));
                    record.put("intentExtraKeys",new org.json.JSONArray(intent.getExtras()==null?java.util.List.of():new java.util.ArrayList<>(intent.getExtras().keySet())));
                }
                items.put(record);
            }
            result.put("items",items);result.put("receivedAtMillis",System.currentTimeMillis());
            Files.write(new File(getFilesDir(),kind+"-clip.json").toPath(),result.toString().getBytes(StandardCharsets.UTF_8));
        } catch(Exception error){throw new IllegalStateException(error);}
    }
    private void openSyntheticGalleryImage() {
        try {
            String prior=getPreferences(0).getString("galleryImage","");android.net.Uri uri;
            if(prior.isEmpty()) {
                android.content.ContentValues values=new android.content.ContentValues();values.put("_display_name","GS-shelf-probe.png");values.put("mime_type","image/png");
                values.put("relative_path","Pictures/GlobalSend-test");values.put("is_pending",1);
                uri=getContentResolver().insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI,values);
                if(uri==null)throw new java.io.IOException("No image row");
                try(java.io.InputStream input=getContentResolver().openInputStream(android.net.Uri.parse("content://dev.globalsend.shelfacceptance.probe/probe.png"));java.io.OutputStream out=getContentResolver().openOutputStream(uri)){input.transferTo(out);}
                values.clear();values.put("is_pending",0);getContentResolver().update(uri,values,null,null);
                getPreferences(0).edit().putString("galleryImage",uri.toString()).apply();
            }else uri=android.net.Uri.parse(prior);
            startActivity(new android.content.Intent(android.content.Intent.ACTION_VIEW).setDataAndType(uri,"image/png").setPackage("com.vivo.gallery").addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION));
        } catch(Exception error){throw new IllegalStateException(error);}
    }
    private void removeSyntheticGalleryImage() {
        String prior=getPreferences(0).getString("galleryImage","");
        if(!prior.isEmpty()) {
            // Only this fixture's saved insert result; never enumerate/delete
            // the user's Gallery or the containing directory.
            getContentResolver().delete(android.net.Uri.parse(prior),null,null);
            getPreferences(0).edit().remove("galleryImage").apply();
        }
        android.widget.Toast.makeText(this,"测试图已移除",android.widget.Toast.LENGTH_SHORT).show();
    }
    private void applyRotation(android.content.Intent intent) {
        String orientation=intent.getStringExtra("orientation");
        if("landscape".equals(orientation))setRequestedOrientation(android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE);
        else if("portrait".equals(orientation))setRequestedOrientation(android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT);
        else if("release".equals(orientation))setRequestedOrientation(android.content.pm.ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED);
    }
    private TextView label(String text, int size) {
        TextView view = new TextView(this);
        view.setText(text); view.setTextSize(size); view.setTextColor(Color.rgb(35, 42, 39));
        return view;
    }
    /** Cross-UID real-path check only; does not assert OS-drop/WeChat acceptance. */
    public static final class LegacyPathReader extends Activity {
        @Override public void onCreate(Bundle state) {
            super.onCreate(state);JSONObject report=new JSONObject();
            TextView status=new TextView(this);status.setTextSize(20);setContentView(status);
            try {
                android.net.Uri uri=getIntent().getData();
                report.put("scope","Cross-UID production-provider path read with explicit intent grant; not an OS drag or target-app insertion");
                report.put("sourceUid",getIntent().getIntExtra("sourceUid",-1));report.put("targetUid",android.os.Process.myUid());
                report.put("sdk",android.os.Build.VERSION.SDK_INT);
                report.put("receivedAtMillis",System.currentTimeMillis());
                String mime=getIntent().getType();report.put("mime",mime);
                report.put("imageReadPermission",checkSelfPermission("android.permission.READ_MEDIA_IMAGES")==android.content.pm.PackageManager.PERMISSION_GRANTED);
                report.put("originalUriGranted",checkUriPermission(uri,android.os.Process.myPid(),android.os.Process.myUid(),android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)==android.content.pm.PackageManager.PERMISSION_GRANTED);
                report.put("phase","query");
                try(android.database.Cursor cursor=getContentResolver().query(uri,new String[]{"_data"},null,null,null)) {
                    if(cursor==null || !cursor.moveToFirst() || cursor.isNull(0))throw new java.io.FileNotFoundException("No legacy path");
                    report.put("phase","path-open");report.put("pathExists",new File(cursor.getString(0)).exists());
                    report.put("pathReadable",new File(cursor.getString(0)).canRead());
                    try(java.io.InputStream input=new java.io.FileInputStream(cursor.getString(0))) {
                        byte[] expected="image/png".equals(mime)?new byte[]{(byte)137,80,78,71,13,10,26,10}:"GS-legacy-private".getBytes(StandardCharsets.UTF_8);
                        byte[] bytes=new byte[expected.length];new java.io.DataInputStream(input).readFully(bytes);
                        if(!java.util.Arrays.equals(bytes,expected))throw new java.io.IOException("Not synthetic payload");
                    }
                }
                report.put("readable",true);
            } catch(Exception error) {
                try{report.put("readable",false);report.put("errorType",error.getClass().getSimpleName());
                    Throwable cause=error.getCause();if(cause instanceof android.system.ErrnoException)report.put("errno",((android.system.ErrnoException)cause).errno);
                }catch(Exception ignored){}
            }
            try{Files.write(new File(getFilesDir(),"legacy-intent-outcome.json").toPath(),report.toString(2).getBytes(StandardCharsets.UTF_8));}
            catch(Exception error){throw new IllegalStateException(error);}
            status.setText(report.toString());
        }
    }
    public static final class ImageProvider extends android.content.ContentProvider {
        private File file;
        @Override public boolean onCreate() {
            file=new File(getContext().getFilesDir(),"shelf-probe.png");
            android.graphics.Bitmap bitmap=android.graphics.Bitmap.createBitmap(240,240,android.graphics.Bitmap.Config.ARGB_8888);
            android.graphics.Canvas canvas=new android.graphics.Canvas(bitmap);canvas.drawColor(0xff468fc5);
            android.graphics.Paint paint=new android.graphics.Paint(3);paint.setColor(0xffffde79);canvas.drawCircle(120,120,75,paint);
            paint.setColor(0xff202124);paint.setTextSize(28);canvas.drawText("GS probe",60,130,paint);
            try(java.io.FileOutputStream out=new java.io.FileOutputStream(file)){bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,out);}
            catch(java.io.IOException error){throw new IllegalStateException(error);}finally{bitmap.recycle();}
            return true;
        }
        @Override public String getType(android.net.Uri uri){return "image/png";}
        @Override public android.os.ParcelFileDescriptor openFile(android.net.Uri uri,String mode) throws java.io.FileNotFoundException {
            if(!"r".equals(mode))throw new java.io.FileNotFoundException();
            return android.os.ParcelFileDescriptor.open(file,android.os.ParcelFileDescriptor.MODE_READ_ONLY);
        }
        @Override public android.database.Cursor query(android.net.Uri uri,String[] columns,String selection,String[] args,String order) {
            android.database.MatrixCursor result=new android.database.MatrixCursor(new String[]{"_display_name","_size"});
            result.addRow(new Object[]{"GS-shelf-probe.png",file.length()});return result;
        }
        @Override public android.net.Uri insert(android.net.Uri uri,android.content.ContentValues values){throw new UnsupportedOperationException();}
        @Override public int update(android.net.Uri uri,android.content.ContentValues values,String s,String[] a){throw new UnsupportedOperationException();}
        @Override public int delete(android.net.Uri uri,String s,String[] a){throw new UnsupportedOperationException();}
    }
}
