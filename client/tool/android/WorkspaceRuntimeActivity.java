package dev.globalsend.globalsend;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.provider.DocumentsContract;
import android.view.View;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMethodCodec;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.zip.ZipFile;
import org.json.JSONArray;
import org.json.JSONObject;

/** UI-only consumer of the production Android bridges. Has no network permission. */
public final class WorkspaceRuntimeActivity extends Activity {
    private final Handler handler = new Handler();
    private final JSONObject result = new JSONObject();
    private final JSONArray drops = new JSONArray();
    private final List<String> staged = new ArrayList<>();
    private final Messenger messenger = new Messenger();
    private DockCoordinator coordinator;
    private LinearLayout rows;
    private TextView status;
    private File outputs, image;
    private int clipboardStage = 0;
    private boolean started;
    private String authority() { return getPackageName() + ".documents"; }

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        try {
            outputs = getExternalFilesDir("runtime-results"); outputs.mkdirs();
            result.put("scope", "Android runtime synthetic UI/provider consumer; not physical vivo cross-app acceptance");
            result.put("sdk", android.os.Build.VERSION.SDK_INT); result.put("model", android.os.Build.MODEL);
            result.put("networkPermission", false); result.put("productionClass", DockCoordinator.class.getName());
            File source = WorkspaceDocumentsProvider.source(this); new File(source, "空目录").mkdirs(); new File(source, "nested").mkdirs();
            Files.write(new File(source, "nested/正文.html").toPath(), "<h1>原始中文文件</h1>".getBytes(StandardCharsets.UTF_8));
            Files.write(new File(source, "empty.txt").toPath(), new byte[0]);
            image = new File(source, "图片预览.png");
            Bitmap art = Bitmap.createBitmap(1400, 900, Bitmap.Config.ARGB_8888); Canvas canvas = new Canvas(art); Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
            canvas.drawColor(0xffdcecf0); paint.setColor(0xffe6b85e); canvas.drawCircle(1100, 190, 150, paint);
            paint.setColor(0xff559884); canvas.drawOval(100, 300, 1500, 1300, paint); paint.setColor(0xff246959); canvas.drawOval(-300, 560, 1000, 1200, paint);
            try (FileOutputStream out = new FileOutputStream(image)) { art.compress(Bitmap.CompressFormat.PNG, 100, out); } art.recycle();
            LinearLayout page = new LinearLayout(this); page.setOrientation(LinearLayout.VERTICAL); page.setPadding(dp(18), dp(20), dp(18), dp(20)); page.setBackgroundColor(0xfff2f5f1);
            ScrollView scroll = new ScrollView(this); scroll.addView(page); setContentView(scroll);
            TextView title = new TextView(this); title.setText("GlobalSend · Android 运行检查"); title.setTextSize(20); title.setTextColor(0xff233b31); page.addView(title);
            page.addView(shadow(null, "组内共享的中文文本，第二行也可完整保留。", "中文文本" , "drag-text"));
            page.addView(shadow(image.getAbsolutePath(), null, "山色与日光 · 图片预览.png", "drag-image"));
            Button folder = new Button(this); folder.setText("选择测试目录"); page.addView(folder);
            folder.setOnClickListener(view -> invoke("pickDirectoryArchive", new HashMap<>(), value -> checkArchive((Map<?, ?>) value, true)));
            TextView hint = new TextView(this); hint.setText("目录：GlobalSend UI fixtures；只读取测试原件，不使用网络。"); page.addView(hint);
            status = new TextView(this); status.setTextSize(14); page.addView(status);
            rows = new LinearLayout(this); rows.setOrientation(LinearLayout.VERTICAL); page.addView(rows);
            coordinator = new DockCoordinator(this, new MethodChannel(messenger, "dev.globalsend/dock"));
            write();
        } catch (Throwable error) { fail(error); }
    }

    private int dp(float value) { return Math.round(value * getResources().getDisplayMetrics().density); }

    private View shadow(String path, String text, String label, String name) throws Exception {
        Class<?> previewClass = Class.forName("dev.globalsend.globalsend.DockCoordinator$DragPreview");
        java.lang.reflect.Constructor<?> constructor = previewClass.getDeclaredConstructor(View.class, String.class, String.class, String.class); constructor.setAccessible(true);
        View preview = (View) constructor.newInstance(new View(this), path, text, label);
        int width = dp(232), height = dp(104);
        preview.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY)); preview.layout(0, 0, width, height);
        Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        new View.DragShadowBuilder(preview).onDrawShadow(new Canvas(bitmap));
        try (FileOutputStream out = new FileOutputStream(new File(outputs, name + ".png"))) { bitmap.compress(Bitmap.CompressFormat.PNG, 100, out); }
        Bitmap compressed = Bitmap.createScaledBitmap(bitmap, 464, 208, true);
        try (FileOutputStream out = new FileOutputStream(new File(outputs, name + ".preview.jpg"))) { compressed.compress(Bitmap.CompressFormat.JPEG, 78, out); }
        compressed.recycle();
        JSONObject metadata = new JSONObject(); metadata.put("width", width); metadata.put("height", height); metadata.put("cornerAlpha", Color.alpha(bitmap.getPixel(2, 2)));
        if (path != null) {
            java.lang.reflect.Field field = previewClass.getDeclaredField("bitmap"); field.setAccessible(true); Bitmap decoded = (Bitmap) field.get(preview);
            if (decoded == null) throw new AssertionError("Production thumbnail decoder returned no bitmap");
            metadata.put("decodedWidth", decoded.getWidth()); metadata.put("decodedHeight", decoded.getHeight());
            if (Math.max(decoded.getWidth(), decoded.getHeight()) > 300) throw new AssertionError("Thumbnail decode was not bounded");
        }
        result.put(name, metadata);
        ImageView view = new ImageView(this); view.setImageBitmap(bitmap); view.setAdjustViewBounds(true);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(width, height); params.topMargin = dp(16); params.bottomMargin = dp(12); view.setLayoutParams(params);
        view.setOnLongClickListener(source -> {
            try { DockCoordinator.startDrag(source, path, text, label); result.put("actualDragStarted", true); write(); return true; }
            catch (Exception error) { fail(error); return false; }
        });
        return view;
    }

    @Override public void onResume() {
        super.onResume();
        if (!started && coordinator != null) { started = true; handler.postDelayed(this::startClipboard, 900); }
    }
    private void startClipboard() {
        try {
            result.put("clipboardInitialDropCount", drops.length());
            ((ClipboardManager) getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText("GlobalSend fixture", "剪贴板中文入队：只添加，不发送。"));
            clipboardStage = 1; invoke("importClipboard", new HashMap<>(), ignored -> {});
        } catch (Throwable error) { fail(error); }
    }
    private void onDrop(Map<?, ?> event) {
        try {
            if (event.get("error") != null) throw new AssertionError(event.get("error"));
            drops.put(new JSONObject(event));
            List<?> texts = (List<?>) event.get("texts"), paths = (List<?>) event.get("paths");
            for (Object text : texts) { staged.add(text.toString()); addRow("文本 · " + text); }
            for (Object path : paths) { staged.add(path.toString()); addRow("图片 · " + new File(path.toString()).getName()); }
            if (clipboardStage == 1) {
                if (!texts.contains("剪贴板中文入队：只添加，不发送。")) throw new AssertionError("Clipboard text did not enter native queue");
                result.put("clipboardTextQueued", true); clipboardStage = 2;
                Uri uri = DocumentsContract.buildDocumentUri(authority(), "root/图片预览.png");
                ((ClipboardManager) getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newUri(getContentResolver(), "图片", uri));
                handler.postDelayed(() -> invoke("importClipboard", new HashMap<>(), ignored -> {}), 150);
            } else if (clipboardStage == 2) {
                File imported = new File(paths.get(0).toString());
                if (!Arrays.equals(Files.readAllBytes(image.toPath()), Files.readAllBytes(imported.toPath()))) throw new AssertionError("Imported clipboard image changed");
                result.put("clipboardImageQueued", true); result.put("clipboardImageBytes", imported.length()); clipboardStage = 3;
            }
            result.put("stagedCount", staged.size()); result.put("drops", drops); write();
        } catch (Throwable error) { fail(error); }
    }

    private void checkArchive(Map<?, ?> value, boolean fromPicker) {
        try {
            File archive = new File(value.get("path").toString()); JSONArray names = new JSONArray();
            try (ZipFile zip = new ZipFile(archive)) {
                zip.stream().forEach(entry -> names.put(entry.getName()));
                String prefix = fromPicker ? "资料/" : "nested/";
                if (zip.getEntry(prefix) == null || zip.getEntry(prefix + (fromPicker ? "空目录/" : "正文.html")) == null) throw new AssertionError("Directory structure missing");
                String html = new String(zip.getInputStream(zip.getEntry(prefix + (fromPicker ? "nested/正文.html" : "正文.html"))).readAllBytes(), StandardCharsets.UTF_8);
                if (!"<h1>原始中文文件</h1>".equals(html)) throw new AssertionError("HTML original mismatch");
            }
            if (!new String(Files.readAllBytes(new File(WorkspaceDocumentsProvider.source(this), "nested/正文.html").toPath()), StandardCharsets.UTF_8).equals("<h1>原始中文文件</h1>")) throw new AssertionError("Original changed");
            JSONObject archiveResult = new JSONObject(); archiveResult.put("entries", names); archiveResult.put("bytes", archive.length()); archiveResult.put("source", value.get("source")); archiveResult.put("originalPreserved", true);
            result.put(fromPicker ? "safPickerArchive" : "safNestedRearchive", archiveResult);
            addRow("文件夹 · " + value.get("name") + ".zip"); staged.add(archive.getAbsolutePath());
            if (fromPicker) {
                Uri root = Uri.parse(value.get("source").toString());
                Uri nested = DocumentsContract.buildDocumentUriUsingTree(root, "root/nested");
                Map<String, Object> args = new HashMap<>(); args.put("location", nested.toString());
                invoke("archiveDirectory", args, next -> checkArchive((Map<?, ?>) next, false));
            } else { result.put("complete", true); }
            result.put("stagedCount", staged.size()); write();
        } catch (Throwable error) { fail(error); }
    }

    private void addRow(String value) { TextView row = new TextView(this); row.setText(value); row.setPadding(0, dp(8), 0, dp(8)); rows.addView(row); }
    interface Success { void receive(Object value); }
    private void invoke(String method, Map<String, ?> args, Success success) {
        ByteBuffer input = StandardMethodCodec.INSTANCE.encodeMethodCall(new MethodCall(method, args)); input.flip();
        messenger.handler.onMessage(input, reply -> {
            try { reply.flip(); Object value = StandardMethodCodec.INSTANCE.decodeEnvelope(reply); success.receive(value); }
            catch (Throwable error) { fail(error); }
        });
    }
    private final class Messenger implements BinaryMessenger {
        BinaryMessageHandler handler;
        @Override public void setMessageHandler(String name, BinaryMessageHandler callback) { handler = callback; }
        @Override public void send(String name, ByteBuffer bytes) { send(name, bytes, null); }
        @Override public void send(String name, ByteBuffer bytes, BinaryReply reply) {
            ByteBuffer copy = bytes.duplicate(); copy.flip(); MethodCall call = StandardMethodCodec.INSTANCE.decodeMethodCall(copy);
            if ("nativeDrop".equals(call.method)) onDrop((Map<?, ?>) call.arguments);
            if (reply != null) reply.reply(null);
        }
    }
    private void fail(Throwable error) {
        try { result.put("error", android.util.Log.getStackTraceString(error)); write(); } catch (Exception ignored) {}
        android.util.Log.e("GlobalSendWorkspace", "Runtime check failed", error);
    }
    private void write() {
        try {
            Files.write(new File(outputs, "result.json").toPath(), result.toString(2).getBytes(StandardCharsets.UTF_8));
            if (status != null) status.setText(result.has("error") ? "失败：" + result.optString("error") : result.optBoolean("complete") ? "全部通过 · 目录原件保留" : "剪贴板已验证，等待选择测试目录");
        } catch (Exception error) { android.util.Log.e("GlobalSendWorkspace", "Could not write result", error); }
    }
    @Override protected void onActivityResult(int request, int response, Intent data) { if (coordinator != null && coordinator.onActivityResult(request, response, data)) return; super.onActivityResult(request, response, data); }
    @Override protected void onDestroy() { if (coordinator != null) coordinator.dispose(); handler.removeCallbacksAndMessages(null); super.onDestroy(); }
}
