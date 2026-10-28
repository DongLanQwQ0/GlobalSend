package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.app.Activity;
import android.graphics.Insets;
import android.view.View;
import android.view.WindowInsets;
import android.widget.ScrollView;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk=34,manifest=Config.NONE)
public class IntegrationUiInsetsTest {
    private WindowInsets insets(Insets status,Insets navigation,Insets cutout) {
        return new WindowInsets.Builder()
            .setInsets(WindowInsets.Type.statusBars(),status)
            .setInsets(WindowInsets.Type.navigationBars(),navigation)
            .setInsets(WindowInsets.Type.displayCutout(),cutout)
            .build();
    }
    @Test public void dispatchReservesBarsAndCutoutWithoutAccumulatingOrChangingBodySpacing() {
        Activity activity=Robolectric.buildActivity(Activity.class).setup().get();
        IntegrationUi ui=new IntegrationUi(activity,"应用联动");ScrollView viewport=(ScrollView)ui.body.getParent();
        WindowInsets portrait=insets(Insets.of(0,24,0,0),Insets.of(0,0,0,28),Insets.of(10,48,6,0));
        viewport.dispatchApplyWindowInsets(portrait);
        assertEquals(10,viewport.getPaddingLeft());assertEquals(48,viewport.getPaddingTop());assertEquals(6,viewport.getPaddingRight());assertEquals(28,viewport.getPaddingBottom());
        viewport.dispatchApplyWindowInsets(portrait);
        assertEquals(48,viewport.getPaddingTop());assertEquals(28,viewport.getPaddingBottom());
        assertEquals(ui.dp(24),ui.body.getPaddingLeft());assertEquals(ui.dp(24),ui.body.getPaddingTop());assertEquals(ui.dp(24),ui.body.getPaddingRight());assertEquals(ui.dp(24),ui.body.getPaddingBottom());
        viewport.measure(View.MeasureSpec.makeMeasureSpec(420,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(820,View.MeasureSpec.EXACTLY));viewport.layout(0,0,420,820);
        assertEquals(48+ui.dp(24),ui.body.getTop()+ui.body.getChildAt(0).getTop());
        assertTrue(ui.body.getBottom()<=820-28);
    }
    @Test public void changedAndRemovedInsetsReplaceThePreviousSafeArea() {
        Activity activity=Robolectric.buildActivity(Activity.class).setup().get();
        IntegrationUi ui=new IntegrationUi(activity,"应用联动");ScrollView viewport=(ScrollView)ui.body.getParent();
        viewport.dispatchApplyWindowInsets(insets(Insets.of(0,24,0,0),Insets.of(0,0,0,28),Insets.of(0,48,0,0)));
        viewport.dispatchApplyWindowInsets(insets(Insets.NONE,Insets.of(0,0,20,0),Insets.of(50,0,0,0)));
        assertEquals(50,viewport.getPaddingLeft());assertEquals(0,viewport.getPaddingTop());assertEquals(20,viewport.getPaddingRight());assertEquals(0,viewport.getPaddingBottom());
        viewport.dispatchApplyWindowInsets(insets(Insets.NONE,Insets.NONE,Insets.NONE));
        assertEquals(0,viewport.getPaddingLeft());assertEquals(0,viewport.getPaddingTop());assertEquals(0,viewport.getPaddingRight());assertEquals(0,viewport.getPaddingBottom());
        assertEquals(ui.dp(24),ui.body.getPaddingTop());assertEquals(ui.dp(24),ui.body.getPaddingBottom());
    }
}
