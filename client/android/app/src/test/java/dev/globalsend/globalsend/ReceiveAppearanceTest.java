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
    @Test public void readsFlutterPreferenceAndKeepsNeutralDistinctFromDark() throws Exception {
        Context context = RuntimeEnvironment.getApplication();
        File file = new File(context.getFilesDir(),"appearance.json");
        try (FileOutputStream output = new FileOutputStream(file)) {
            output.write("{\"mode\":\"dark\",\"accent\":\"blue\"}".getBytes(StandardCharsets.UTF_8));
        }
        ReceiveAppearance p=ReceiveAppearance.load(context);
        assertEquals(0xff1c2324,p.surface);assertEquals(0xffe6eeee,p.ink);assertEquals(0xff9ecaff,p.accent);
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
        assertEquals(0xf51c2324,((GradientDrawable)root.getBackground()).getColor().getDefaultColor());
        field=ReceiveOverlay.class.getDeclaredField("row");field.setAccessible(true);
        LinearLayout row=(LinearLayout)field.get(overlay),card=(LinearLayout)row.getChildAt(0);
        TextView text=(TextView)card.getChildAt(0);assertEquals(0xffe6eeee,text.getCurrentTextColor());
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
