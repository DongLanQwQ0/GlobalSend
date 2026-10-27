package dev.globalsend.globalsend;

import android.app.Activity;
import android.view.MotionEvent;

/** Retired Activity-scaling adapter. Kept inert for older integration callers. */
final class ReceiveWindowPresentation {
    enum Result { SHOWN, REJECTED, UNSUPPORTED }
    interface Translucency { boolean set(Activity activity, boolean value); }
    ReceiveWindowPresentation(Activity activity) { }
    ReceiveWindowPresentation(Activity activity, Translucency translucency) { }
    boolean isFloating() { return false; }
    Result show() { return Result.UNSUPPORTED; }
    boolean adjust(float dx, float dy, float dw, float dh) { return false; }
    void observeTouch(MotionEvent event) { }
    boolean beginGesture(long downTime, boolean resize) { return false; }
    boolean endGesture(long downTime) { return false; }
    void cancelGesture() { }
    boolean restore() { return true; }
}
