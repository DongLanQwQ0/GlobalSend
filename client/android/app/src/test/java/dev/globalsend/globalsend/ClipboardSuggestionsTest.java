package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.content.ClipData;
import android.content.ClipDescription;
import android.content.ClipboardManager;
import android.content.Context;
import android.net.Uri;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk=28,manifest=Config.NONE)
public class ClipboardSuggestionsTest {
    @Test public void queueAndShelfShareOneDismissedRevisionWithoutImportingAnything() {
        Context context=RuntimeEnvironment.getApplication();
        ClipboardManager clipboard=context.getSystemService(ClipboardManager.class);
        AtomicInteger changes=new AtomicInteger();
        ClipboardSuggestions suggestions=new ClipboardSuggestions(context,changes::incrementAndGet);
        try {
            clipboard.setPrimaryClip(ClipData.newPlainText("fixture","clipboard text"));
            Map<String,Object> first=suggestions.refresh(true);
            assertEquals("text",first.get("kind"));
            suggestions.dismiss((String)first.get("revision"));
            assertEquals("empty",suggestions.snapshot().get("kind"));
            assertEquals("empty",suggestions.refresh(true).get("kind"));
            ClipData image=new ClipData(new ClipDescription("image",new String[]{"image/png"}),new ClipData.Item(Uri.parse("content://fixture/photo/1")));
            clipboard.setPrimaryClip(image);
            Map<String,Object> next=suggestions.refresh(true);
            assertEquals("image",next.get("kind"));assertNotEquals(first.get("revision"),next.get("revision"));
            assertEquals(next,suggestions.refresh(false));
            clipboard.setPrimaryClip(new ClipData(new ClipDescription("files",new String[]{ClipDescription.MIMETYPE_TEXT_URILIST}),new ClipData.Item(Uri.parse("content://fixture/file/1"))));
            assertEquals("files",suggestions.refresh(true).get("kind"));
            assertTrue(changes.get()>=3);
        } finally {suggestions.dispose();}
    }
}
