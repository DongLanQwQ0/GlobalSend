package dev.globalsend.globalsend;

import android.app.Activity;
import android.content.ClipData;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.provider.DocumentsContract;
import android.provider.OpenableColumns;
import java.util.Locale;

/** External viewers and the package installer consume the same granted URI. */
final class AndroidFileOpener {
    static final String APK = "application/vnd.android.package-archive";

    static Intent viewIntent(Context context, Uri document) {
        String type = context.getContentResolver().getType(document);
        String name = document.getLastPathSegment();
        boolean generic = type == null || "application/octet-stream".equals(type) || "application/zip".equals(type);
        if (generic && (name == null || !name.toLowerCase(Locale.ROOT).endsWith(".apk"))) {
            try (Cursor cursor = context.getContentResolver().query(document,
                    new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
                if (cursor != null && cursor.moveToFirst() && !cursor.isNull(0)) name = cursor.getString(0);
            } catch (UnsupportedOperationException noMetadata) {
                // A stream-only provider still keeps its original viewer path.
            }
        }
        // Documents providers may report APKs as generic bytes or ZIP files.
        if (!DocumentsContract.Document.MIME_TYPE_DIR.equals(type) &&
                name != null && name.toLowerCase(Locale.ROOT).endsWith(".apk")) type = APK;
        Intent intent = new Intent(Intent.ACTION_VIEW)
            .setDataAndType(document, type == null ? "application/octet-stream" : type)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        intent.setClipData(ClipData.newRawUri("GlobalSend", document));
        if (APK.equals(type) || !(context instanceof Activity)) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        return intent;
    }

    static void open(Context context, Uri document) {
        // The system owns installation consent and any unknown-source prompt.
        context.startActivity(viewIntent(context, document));
    }
}
