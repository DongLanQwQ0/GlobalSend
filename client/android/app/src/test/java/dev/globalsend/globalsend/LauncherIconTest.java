package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.drawable.VectorDrawable;
import android.graphics.drawable.Drawable;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.GraphicsMode;

/** Render the resource selected by the package installer, not an unrelated SVG. */
@RunWith(RobolectricTestRunner.class)
@Config(sdk=34, manifest=Config.NONE)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
public class LauncherIconTest {
    @Test public void installerUsesTransparentVectorWithClearSpaceAroundTheCompleteMark() throws Exception {
        Drawable icon=RuntimeEnvironment.getApplication().getDrawable(R.mipmap.ic_launcher);
        assertTrue("installer must select scalable artwork, not a small PNG",icon instanceof VectorDrawable);
        int size=384,visible=0;
        Bitmap image=Bitmap.createBitmap(size,size,Bitmap.Config.ARGB_8888);
        icon.setBounds(0,0,size,size);icon.draw(new Canvas(image));
        int left=size,top=size,right=-1,bottom=-1;double radius=0;
        for(int y=0;y<size;y++)for(int x=0;x<size;x++) {
            if(Color.alpha(image.getPixel(x,y))<8)continue;
            visible++;left=Math.min(left,x);top=Math.min(top,y);right=Math.max(right,x);bottom=Math.max(bottom,y);
            radius=Math.max(radius,Math.hypot(x-size/2f,y-size/2f));
        }
        String output=System.getenv("GLOBALSEND_ICON_TEST_ARTIFACTS");
        if(output!=null) {
            java.io.File directory=new java.io.File(output);directory.mkdirs();
            Bitmap preview=Bitmap.createBitmap(size,size,Bitmap.Config.ARGB_8888);
            Canvas canvas=new Canvas(preview);canvas.drawColor(Color.WHITE);canvas.drawBitmap(image,0,0,null);
            try(java.io.OutputStream stream=new java.io.FileOutputStream(new java.io.File(directory,"installer-icon-after.jpg"))) {
                preview.compress(Bitmap.CompressFormat.JPEG,92,stream);
            }
            preview.recycle();
        }
        assertTrue("artwork stays inside even a circular OEM mask: radius="+radius+" bbox="+left+","+top+","+right+","+bottom,radius<size/2f-12);
        assertTrue(visible>10000);
        assertTrue("outer ring retains its intended size",right-left>size*.65f);
        assertTrue(left>12 && top>12 && right<size-12 && bottom<size-12);
        assertEquals("no colored backing",0,Color.alpha(image.getPixel(size/2,size/2)));
        image.recycle();
    }
}
