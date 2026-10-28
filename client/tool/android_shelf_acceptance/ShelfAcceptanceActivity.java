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
        destination = label("将暂存项拖到这里\n只接受 GS-shelf-physical 测试文本", 18);
        destination.setContentDescription("fixture-target");
        destination.setGravity(Gravity.CENTER);
        destination.setBackgroundColor(0xffe6e8ec);
        destination.setOnDragListener((view, event) -> {
            if (event.getAction() == DragEvent.ACTION_DRAG_STARTED) return true;
            if (event.getAction() != DragEvent.ACTION_DROP) return true;
            ClipData clip = event.getClipData();
            if (clip == null || clip.getItemCount() == 0) return false;
            for (int i = 0; i < clip.getItemCount(); i++) {
                CharSequence text = clip.getItemAt(i).getText();
                if (text == null || !text.toString().startsWith("GS-shelf-physical:")) return false;
            }
            accepted++;
            destination.setText("系统已接收 " + accepted + " 次测试投放");
            try {
                JSONObject result = new JSONObject();
                result.put("acceptedDrops", accepted);
                result.put("items", clip.getItemCount());
                result.put("receivedAtMillis", System.currentTimeMillis());
                result.put("syntheticOnly", true);
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
