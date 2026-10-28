package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.content.Context;
import android.graphics.drawable.GradientDrawable;
import android.view.View;
import android.view.WindowManager;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk=34, manifest=Config.NONE)
public class ReceiveAppearanceTest {
    @Test @org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
    public void nativeDragArtworkUsesSelectedPaletteAndResolvesSystemNightMode() throws Exception {
        Context context = RuntimeEnvironment.getApplication();
        File file = new File(context.getFilesDir(), "appearance.json");
        String directory = System.getenv("GLOBALSEND_TEST_ARTIFACTS");
        for (String mode : new String[]{"light", "dark", "neutral"}) {
            java.nio.file.Files.write(file.toPath(), ("{\"mode\":\"" + mode + "\",\"accent\":\"purple\"}").getBytes(StandardCharsets.UTF_8));
            ReceiveAppearance palette = ReceiveAppearance.load(context);
            View preview = new DockCoordinator.DragPreview(new View(context), null, "https://joinflow.koala-studio.org.cn", "1 项");
            float dp = context.getResources().getDisplayMetrics().density;
            int width = Math.round(232 * dp), height = Math.round(104 * dp);
            preview.layout(0, 0, width, height);
            android.graphics.Bitmap image = android.graphics.Bitmap.createBitmap(width, height, android.graphics.Bitmap.Config.ARGB_8888);
            preview.draw(new android.graphics.Canvas(image));
            assertEquals(palette.surface, image.getPixel(Math.round(110 * dp), Math.round(80 * dp)));
            assertEquals(palette.soft, image.getPixel(Math.round(20 * dp), Math.round(50 * dp)));
            assertEquals(palette.accent, image.getPixel(Math.round(35 * dp), Math.round(50 * dp)));
            if (directory != null) try (FileOutputStream output = new FileOutputStream(new File(directory, "android-drag-" + mode + ".png"))) {
                image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output);
            }
        }
        java.nio.file.Files.write(file.toPath(), "{\"mode\":\"system\",\"accent\":\"purple\"}".getBytes(StandardCharsets.UTF_8));
        org.robolectric.RuntimeEnvironment.setQualifiers("night");
        assertEquals(0xffc9b6ff, ReceiveAppearance.load(context).accent);
        org.robolectric.RuntimeEnvironment.setQualifiers("notnight");
        assertEquals(0xff7051a8, ReceiveAppearance.load(context).accent);
        assertTrue(file.delete());
    }
    @Test public void readsFlutterPreferenceAndKeepsNeutralDistinctFromDark() throws Exception {
        Context context = RuntimeEnvironment.getApplication();
        File file = new File(context.getFilesDir(),"appearance.json");
        try (FileOutputStream output = new FileOutputStream(file)) {
            output.write("{\"mode\":\"dark\",\"accent\":\"blue\"}".getBytes(StandardCharsets.UTF_8));
        }
        ReceiveAppearance p=ReceiveAppearance.load(context);
        assertEquals(0xff202124,p.surface);assertEquals(0xffe9eaed,p.ink);assertEquals(0xff9ecaff,p.accent);
        assertNotEquals(new ReceiveAppearance("dark","green").field,p.field);
        ReceiveAppearance neutral=new ReceiveAppearance("neutral","purple");
        assertEquals(0xfff7f7f8,neutral.surface);assertEquals(0xff7051a8,neutral.accent);
        assertTrue(file.delete());
    }

    @Test @org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
    public void independentOverlayUsesDarkSurfacesAndReadableText() throws Exception {
        Context context = RuntimeEnvironment.getApplication();
        File file = new File(context.getFilesDir(),"appearance.json");
        try (FileOutputStream output = new FileOutputStream(file)) {
            output.write("{\"mode\":\"dark\",\"accent\":\"blue\"}".getBytes(StandardCharsets.UTF_8));
        }
        ReceiveOverlay overlay=new ReceiveOverlay(context,new ReceiveOverlay.Actions() {
            public void open(String id) {} public void copy(String id) {}
            public void dismiss(Map<String,String> versions,long generation) {}
        });
        overlay.show(new ReceiveNotifications.Receipt("theme","1","电脑","暗色接收小窗",null,null,0),1,shown -> {});
        java.lang.reflect.Field field=ReceiveOverlay.class.getDeclaredField("root");field.setAccessible(true);
        View root=(View)field.get(overlay);assertNotNull(root);
        assertEquals(0xf5202124,((GradientDrawable)root.getBackground()).getColor().getDefaultColor());
        field=ReceiveOverlay.class.getDeclaredField("row");field.setAccessible(true);
        LinearLayout row=(LinearLayout)field.get(overlay),card=(LinearLayout)row.getChildAt(0);
        TextView text=(TextView)card.getChildAt(0);assertEquals(0xffe9eaed,text.getCurrentTextColor());
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        WindowManager.LayoutParams size=(WindowManager.LayoutParams)root.getLayoutParams();
        root.measure(View.MeasureSpec.makeMeasureSpec(size.width,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(size.height,View.MeasureSpec.EXACTLY));
        root.layout(0,0,size.width,size.height);root.setAlpha(1);root.setTranslationX(0);root.setScaleX(1);root.setScaleY(1);
        String output=System.getenv("GLOBALSEND_TEST_ARTIFACTS");
        if (output!=null) {
            android.graphics.Bitmap image=android.graphics.Bitmap.createBitmap(size.width,size.height,android.graphics.Bitmap.Config.ARGB_8888);
            root.draw(new android.graphics.Canvas(image));
            try (FileOutputStream stream=new FileOutputStream(new File(output,"android-overlay-dark.png"))) {
                image.compress(android.graphics.Bitmap.CompressFormat.PNG,100,stream);
            }
        }
        overlay.hide();org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(200));
        assertTrue(file.delete());
    }
}
