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
                for(String value:getSharedPreferences("legacy-source-fixtures",0).getAll().keySet()) {
                    getContentResolver().delete(Uri.parse(value),null,null);
                    getSharedPreferences("legacy-source-fixtures",0).edit().remove(value).commit();
                }
                for(String value:getSharedPreferences("drag-path-read-grants",0).getAll().keySet()) {
                    getSharedPreferences("drag-path-read-grants",0).edit().putLong(value,0).commit();
                    LegacyDragFiles.expireReadGrant(this,Uri.parse(value));
                }
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
            Uri uri;
            if(getIntent().getBooleanExtra("publicSource",false) || getIntent().getBooleanExtra("mediaSource",false)) {
                android.content.ContentValues values=new android.content.ContentValues();
                values.put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME,source.getName());
                values.put(android.provider.MediaStore.MediaColumns.MIME_TYPE,picture?"image/png":"application/pdf");
                values.put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH,"Download/GlobalSend/Probe");
                values.put(android.provider.MediaStore.MediaColumns.IS_PENDING,1);
                Uri row=getContentResolver().insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI,values);
                if(row==null)throw new java.io.IOException("No synthetic public row");
                getSharedPreferences("legacy-source-fixtures",0).edit().putBoolean(row.toString(),true).commit();
                try(java.io.InputStream input=new java.io.FileInputStream(source);java.io.OutputStream output=getContentResolver().openOutputStream(row,"w")) {input.transferTo(output);}
                values.clear();values.put(android.provider.MediaStore.MediaColumns.IS_PENDING,0);getContentResolver().update(row,values,null,null);
                String path;
                try(android.database.Cursor cursor=getContentResolver().query(row,new String[]{"_data"},null,null,null)){if(cursor==null || !cursor.moveToFirst())throw new java.io.IOException("Missing fixture path");path=cursor.getString(0);}
                uri=getIntent().getBooleanExtra("mediaSource",false)?DockShareProvider.registerReadSource(this,row.toString()):DockShareProvider.register(this,new File(path),source.getName());
            }else uri=DockShareProvider.register(this,source,source.getName());
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
