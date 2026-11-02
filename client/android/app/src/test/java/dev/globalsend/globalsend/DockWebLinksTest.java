package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.content.Intent;
import android.os.Looper;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.GraphicsMode;

@RunWith(RobolectricTestRunner.class) @Config(sdk=34,manifest=Config.NONE)
public class DockWebLinksTest {
    private final int[] appOpenRequests={0};
    @Test public void linksKeepChineseProseOutsideAsciiHostsAndPreserveRealPaths() {
        var links=DockWebLinks.find("导师https://zds.zju.edu.cn可查看更多。见 https://example.com/资料?q=中文，或www.example.org/a_(b). ");
        assertEquals(3,links.size());
        assertEquals("https://zds.zju.edu.cn",links.get(0).uri.toString());
        assertEquals("https://example.com/资料?q=中文",links.get(1).uri.toString());
        assertEquals("https://www.example.org/a_(b)",links.get(2).uri.toString());
        assertTrue(DockWebLinks.find("普通文字 javascript:alert(1)").isEmpty());
        assertEquals("https",DockWebLinks.find("HTTPS://EXAMPLE.COM/a").get(0).uri.getScheme());
    }
    @Test @GraphicsMode(GraphicsMode.Mode.NATIVE)
    public void actualReceiptLinkTapsOpenTheirOwnBrowserUrlWithoutOpeningTheApp() throws Exception {
        ReceiveOverlay overlay=overlay();
        String value="https://one.test/a\nhttps://two.test/b\n普通文字";
        try {
            overlay.show(new ReceiveNotifications.Receipt("links","1","fixture",value,null,null,0),1,shown -> {});
            Shadows.shadowOf(Looper.getMainLooper()).idle();
            View root=(View)field(overlay,"root");draw(root);
            View card=((LinearLayout)field(overlay,"row")).getChildAt(0);
            TextView text=(TextView)((android.widget.FrameLayout)card).getChildAt(0);
            List<DockWebLinks.Link> links=DockWebLinks.find(value);
            assertTrue(card.isLongClickable());assertNull(text.getMovementMethod());
            var styled=(android.text.Spanned)text.getText();
            assertEquals(2,styled.getSpans(0,styled.length(),android.text.style.UnderlineSpan.class).length);
            for(var color:styled.getSpans(0,styled.length(),android.text.style.ForegroundColorSpan.class))
                assertEquals(((ReceiveAppearance)field(overlay,"appearance")).accent,color.getForegroundColor());
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(250));
            capture(root);
            for(var link:links) {
                float x=text.getLayout().getPrimaryHorizontal(link.start+4)+text.getTotalPaddingLeft();
                float y=text.getLayout().getLineTop(text.getLayout().getLineForOffset(link.start))+text.getTotalPaddingTop()+3;
                tap(card,x,y,false);
                Intent intent=Shadows.shadowOf(RuntimeEnvironment.getApplication()).getNextStartedActivity();
                assertNotNull(intent);assertEquals(Intent.ACTION_VIEW,intent.getAction());assertEquals(link.uri,intent.getData());
                assertEquals(Intent.FLAG_ACTIVITY_NEW_TASK,intent.getFlags()&Intent.FLAG_ACTIVITY_NEW_TASK);
            }
            // Moving or cancelling over a link must not turn its UP into a tap.
            float x=text.getTotalPaddingLeft()+20,y=text.getTotalPaddingTop()+5;
            card.dispatchTouchEvent(MotionEvent.obtain(0,0,MotionEvent.ACTION_DOWN,x,y,0));
            card.dispatchTouchEvent(MotionEvent.obtain(0,16,MotionEvent.ACTION_MOVE,x+30,y,0));
            card.dispatchTouchEvent(MotionEvent.obtain(0,32,MotionEvent.ACTION_UP,x+30,y,0));
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(400));
            assertNull(Shadows.shadowOf(RuntimeEnvironment.getApplication()).getNextStartedActivity());
            tap(card,x,y,true);
            assertNull(Shadows.shadowOf(RuntimeEnvironment.getApplication()).getNextStartedActivity());
            int[] longPressed={0};card.setOnLongClickListener(view -> {longPressed[0]++;return true;});
            long now=android.os.SystemClock.uptimeMillis();
            card.dispatchTouchEvent(MotionEvent.obtain(now,now,MotionEvent.ACTION_DOWN,x,y,0));
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(android.view.ViewConfiguration.getLongPressTimeout()+100));
            card.dispatchTouchEvent(MotionEvent.obtain(now,android.os.SystemClock.uptimeMillis(),MotionEvent.ACTION_UP,x,y,0));
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(400));
            assertEquals(1,longPressed[0]);
            assertNull(Shadows.shadowOf(RuntimeEnvironment.getApplication()).getNextStartedActivity());
            assertEquals(0,appOpenRequests[0]);
            // Padding belongs to the normal card action, not to the nearest URL.
            tap(card,1,card.getHeight()/2f,false);
            assertNull(Shadows.shadowOf(RuntimeEnvironment.getApplication()).getNextStartedActivity());
            assertEquals(1,appOpenRequests[0]);
        } finally {overlay.hide();Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(200));}
    }
    private void tap(View card,float x,float y,boolean cancel) {
        card.dispatchTouchEvent(MotionEvent.obtain(0,0,MotionEvent.ACTION_DOWN,x,y,0));
        card.dispatchTouchEvent(MotionEvent.obtain(0,16,cancel?MotionEvent.ACTION_CANCEL:MotionEvent.ACTION_UP,x,y,0));
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(400));
    }
    private ReceiveOverlay overlay() {
        return new ReceiveOverlay(RuntimeEnvironment.getApplication(),new ReceiveOverlay.Actions() {
            public void open(String id){appOpenRequests[0]++;}
            public void copy(String id){}
            public void dismiss(Map<String,String> versions,long generation){}
        });
    }
    private Object field(Object object,String name) throws Exception {
        var field=object.getClass().getDeclaredField(name);field.setAccessible(true);return field.get(object);
    }
    private void draw(View root) {
        WindowManager.LayoutParams size=(WindowManager.LayoutParams)root.getLayoutParams();
        root.measure(View.MeasureSpec.makeMeasureSpec(size.width,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(size.height,View.MeasureSpec.EXACTLY));
        root.layout(0,0,size.width,size.height);root.getViewTreeObserver().dispatchOnPreDraw();
    }
    private void capture(View root) throws Exception {
        var pixels=android.graphics.Bitmap.createBitmap(root.getWidth(),root.getHeight(),android.graphics.Bitmap.Config.ARGB_8888);
        var canvas=new android.graphics.Canvas(pixels);canvas.drawColor(0xffe9edf1);root.draw(canvas);
        try(var output=new java.io.FileOutputStream(new java.io.File(System.getProperty("java.io.tmpdir"),"dock-links.preview.jpg"))) {
            pixels.compress(android.graphics.Bitmap.CompressFormat.JPEG,82,output);
        } finally {pixels.recycle();}
    }
}
