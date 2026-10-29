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
        destination = label("将暂存项拖到这里\n接受测试文本或 GlobalSend 文件，仅检查读取授权", 18);
        destination.setContentDescription("fixture-target");
        destination.setGravity(Gravity.CENTER);
        destination.setBackgroundColor(0xffe6e8ec);
        destination.setOnDragListener((view, event) -> {
            if (event.getAction() == DragEvent.ACTION_DRAG_STARTED) return true;
            if (event.getAction() != DragEvent.ACTION_DROP) return true;
            ClipData clip = event.getClipData();
            if (clip == null || clip.getItemCount() == 0) return false;
            android.view.DragAndDropPermissions permission=requestDragAndDropPermissions(event);
            int fileItems=0;
            try {
                for (int i = 0; i < clip.getItemCount(); i++) {
                    android.net.Uri uri=clip.getItemAt(i).getUri();
                    if(uri!=null) {
                        if(!"dev.globalsend.globalsend.dock-files".equals(uri.getAuthority()) &&
                            !"dev.globalsend.shelfacceptance.probe".equals(uri.getAuthority()))return false;
                        // Exercise the target-side grant and actual provider FD,
                        // without saving the URI, filename, or user file content.
                        try(java.io.InputStream input=getContentResolver().openInputStream(uri)) {
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
    }
    @Override protected void onNewIntent(android.content.Intent intent) {
        super.onNewIntent(intent);setIntent(intent);applyRotation(intent);
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
