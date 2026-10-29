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
                        if(!"dev.globalsend.globalsend.dock-files".equals(uri.getAuthority()))return false;
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
    }
    private TextView label(String text, int size) {
        TextView view = new TextView(this);
        view.setText(text); view.setTextSize(size); view.setTextColor(Color.rgb(35, 42, 39));
        return view;
    }
}
