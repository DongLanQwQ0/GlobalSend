package dev.globalsend.globalsend;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.widget.TextView;
import java.io.File;
import java.io.FileOutputStream;

/** Uses the unmodified production provider under an isolated, network-free UID. */
public final class LegacyDropSourceActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        TextView status=new TextView(this);status.setTextSize(20);setContentView(status);
        try {
            if(getIntent().getBooleanExtra("cleanup",false)) {
                for(String value:getSharedPreferences("drag-path-exports",0).getAll().keySet())
                    LegacyDragFiles.remove(this,Uri.parse(value));
                status.setText("仅清理本工具的合成导出");return;
            }
            boolean picture=!"file".equals(getIntent().getStringExtra("kind"));
            File source=new File(getFilesDir(),picture?"GS-legacy-private.png":"GS-legacy-private.pdf");
            if(picture) {
                Bitmap image=Bitmap.createBitmap(80,80,Bitmap.Config.ARGB_8888);
                new Canvas(image).drawColor(Color.rgb(32,143,198));
                try(FileOutputStream output=new FileOutputStream(source)){image.compress(Bitmap.CompressFormat.PNG,100,output);}
                finally{image.recycle();}
            } else try(FileOutputStream output=new FileOutputStream(source)) {
                output.write("GS-legacy-private".getBytes(java.nio.charset.StandardCharsets.UTF_8));
            }
            Uri uri=DockShareProvider.register(this,source,source.getName());
            // This isolates Binder/MediaStore/FUSE access from drag dispatch.
            // Actual OS drag and target-app insertion remain separate checks.
            Intent reader=new Intent().setClassName("dev.globalsend.shelfacceptance",
                "dev.globalsend.shelfacceptance.ShelfAcceptanceActivity$LegacyPathReader")
                .setDataAndType(uri,getContentResolver().getType(uri)).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                .putExtra("sourceUid",android.os.Process.myUid());
            status.setText("合成私有图片已通过正式Provider提供");startActivity(reader);
        } catch(Exception error) {status.setText(error.getClass().getSimpleName()+": "+error.getMessage());}
    }
}
