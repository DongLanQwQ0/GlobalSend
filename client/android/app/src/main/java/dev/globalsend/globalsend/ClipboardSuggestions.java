package dev.globalsend.globalsend;

import android.content.ClipDescription;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import java.util.Map;

/** Format metadata only. Clipboard bytes are imported only after a tap. */
final class ClipboardSuggestions {
    private final ClipboardManager clipboard;
    private final SharedPreferences state;
    private final Runnable changed;
    private final long epoch=System.currentTimeMillis();
    private long sequence;
    private final ClipboardManager.OnPrimaryClipChangedListener listener;
    ClipboardSuggestions(Context context,Runnable changed) {
        clipboard=context.getSystemService(ClipboardManager.class);
        state=context.getSharedPreferences("clipboard-suggestion",Context.MODE_PRIVATE);
        sequence=state.getLong("sequence",0);
        this.changed=changed;
        listener=() -> {sequence++;state.edit().putLong("sequence",sequence).apply();refresh(true);};
        clipboard.addPrimaryClipChangedListener(listener);
    }
    Map<String,Object> refresh(boolean focused) {
        // Modern Android only allows the focused app to inspect the clipboard.
        if(!focused)return snapshot();
        ClipDescription description=clipboard.getPrimaryClipDescription();
        String kind="empty",revision="empty";
        if(description!=null) {
            long timestamp=Build.VERSION.SDK_INT>=26?description.getTimestamp():0;
            revision=(timestamp>0?Long.toString(timestamp):Long.toString(epoch))+"-"+sequence;
            kind=description.hasMimeType("image/*")?"image":description.hasMimeType(ClipDescription.MIMETYPE_TEXT_URILIST)?"files":"text";
        }
        if(!revision.equals(state.getString("revision","")) || !kind.equals(state.getString("kind","empty"))) {
            state.edit().putString("revision",revision).putString("kind",kind).apply();
            changed.run();
        }
        return snapshot();
    }
    Map<String,Object> snapshot() {
        String revision=state.getString("revision","");
        String kind=revision.equals(state.getString("dismissed",""))?"empty":state.getString("kind","empty");
        return Map.of("available",true,"revision",revision,"kind",kind);
    }
    void dismiss(String revision) {
        state.edit().putString("dismissed",revision).apply();changed.run();
    }
    void dispose() {clipboard.removePrimaryClipChangedListener(listener);}
}
