package dev.globalsend.globalsend;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewTreeObserver;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.LinkedHashMap;
import java.util.Map;

/** A small independent OS overlay. No Activity, backdrop, or full-display touch surface. */
final class ReceiveOverlay implements ReceiveNotifications.Presenter {
    interface Actions {
        void open(String id);
        void copy(String id);
        void dismiss(Map<String, String> versions, long generation);
    }
    private final Context context;
    private final WindowManager windows;
    private final Actions actions;
    private final LinkedHashMap<String, ReceiveNotifications.Receipt> items = new LinkedHashMap<>();
    private final Handler main = new Handler(Looper.getMainLooper());
    private LinearLayout root, row;
    private HorizontalScrollView scroll;
    private TextView count;
    private WindowManager.LayoutParams layout;
    private long generation;
    private boolean rootAdded;
    private long visibilityRevision, lastHideRevision;
    private float downX, downY;
    private int startX, startY, startWidth, startHeight;
    private static final java.util.concurrent.ExecutorService thumbnails =
        java.util.concurrent.Executors.newSingleThreadExecutor();

    ReceiveOverlay(Context context, Actions actions) {
        this.context = context;
        this.actions = actions;
        windows = context.getSystemService(WindowManager.class);
    }

    @Override public void show(ReceiveNotifications.Receipt item, long arrival, java.util.function.Consumer<Boolean> shown) {
        showWhenReady(item, arrival, shown, ++visibilityRevision);
    }

    private void showWhenReady(ReceiveNotifications.Receipt item, long arrival,
            java.util.function.Consumer<Boolean> shown, long request) {
        if (request <= lastHideRevision) { shown.accept(false); return; }
        final View exportingRoot = root;
        if (exportingRoot != null && DockCoordinator.afterExportFrom(exportingRoot, () -> {
            showWhenReady(item, arrival, shown, request);
        })) return;
        generation = arrival;
        boolean newItem = !items.containsKey(item.id);
        if (newItem) {
            LinkedHashMap<String, ReceiveNotifications.Receipt> next = new LinkedHashMap<>();
            next.put(item.id, item); next.putAll(items);
            items.clear(); items.putAll(next);
        } else { items.put(item.id, item); }
        boolean newWindow = root == null;
        try {
            if (newWindow) create();
            int previousScroll = scroll.getScrollX();
            render();
            if (!newItem) {
                final HorizontalScrollView updated = scroll;
                updated.post(() -> { if (scroll == updated) updated.scrollTo(previousScroll, 0); });
            }
            final View presented = root;
            final boolean[] replied = {false};
            Runnable acknowledge = () -> {
                if (!replied[0]) {
                    replied[0] = true;
                    shown.accept(root == presented && presented.isAttachedToWindow() && presented.getWidth() > 0);
                }
            };
            presented.getViewTreeObserver().addOnPreDrawListener(new ViewTreeObserver.OnPreDrawListener() {
                @Override public boolean onPreDraw() {
                    presented.getViewTreeObserver().removeOnPreDrawListener(this);
                    acknowledge.run();
                    if (newWindow && root == presented) {
                        presented.animate().translationX(0).alpha(1).scaleX(1).scaleY(1)
                            .setInterpolator(new android.view.animation.DecelerateInterpolator())
                            .setDuration(180).start();
                    }
                    return true;
                }
            });
            presented.requestLayout(); presented.invalidate();
            main.postDelayed(() -> {
                if (!replied[0]) {
                    replied[0] = true;
                    if (root == presented && generation == arrival) hide();
                    shown.accept(false);
                }
            }, 800);
        } catch (RuntimeException denied) {
            hide(); shown.accept(false);
        }
    }

    private void create() {
        rootAdded = false;
        root = new LinearLayout(context);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(6), dp(2), dp(6), dp(4));
        root.setBackground(shape(0xf5f7faf6, 18));
        root.setClipToOutline(true);
        root.setElevation(dp(8));
        root.setAlpha(0); root.setTranslationX(dp(20));
        root.setScaleX(.96f); root.setScaleY(.96f);
        LinearLayout header = new LinearLayout(context);
        header.setGravity(Gravity.CENTER_VERTICAL);
        count = label("", 12, 0xff4f625a);
        count.setSingleLine(true);
        header.addView(count, new LinearLayout.LayoutParams(0, dp(30), 1));
        TextView open = control("↗", "打开 GlobalSend", () -> actions.open(items.keySet().iterator().next()));
        TextView close = control("×", "关闭", this::dismiss);
        header.addView(open, new LinearLayout.LayoutParams(dp(32), dp(30)));
        header.addView(close, new LinearLayout.LayoutParams(dp(32), dp(30)));
        installMove(header, false);
        root.addView(header);
        scroll = new HorizontalScrollView(context);
        scroll.setHorizontalScrollBarEnabled(false);
        row = new LinearLayout(context);
        row.setOrientation(LinearLayout.HORIZONTAL);
        scroll.addView(row, new HorizontalScrollView.LayoutParams(-2, -1));
        root.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        // A small bottom grip changes the actual OS window, not a full-screen wrapper.
        TextView resize = label("⌟", 12, 0xff7e9187);
        resize.setGravity(Gravity.RIGHT);
        resize.setContentDescription("拖动调整大小");
        installMove(resize, true);
        root.addView(resize, new LinearLayout.LayoutParams(-1, dp(12)));
        layout = new WindowManager.LayoutParams(dp(244), dp(156),
            Build.VERSION.SDK_INT >= 26 ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY : WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL |
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT);
        layout.gravity = Gravity.TOP | Gravity.LEFT;
        layout.setTitle("GlobalSend 接收");
        Rect bounds = availableBounds();
        layout.width = Math.min(layout.width, bounds.width() - dp(16));
        layout.height = Math.min(layout.height, bounds.height() - dp(16));
        layout.x = bounds.right - layout.width - dp(8);
        layout.y = bounds.bottom - layout.height - dp(12);
        windows.addView(root, layout);
        rootAdded = true;
    }

    private void render() {
        row.removeAllViews();
        count.setText("收到 " + items.size() + " 项");
        int side = Math.max(1, layout.height - dp(48));
        for (ReceiveNotifications.Receipt receipt : items.values()) {
            LinearLayout card = new LinearLayout(context);
            card.setOrientation(LinearLayout.VERTICAL);
            card.setPadding(dp(8), dp(6), dp(8), dp(4));
            card.setBackground(shape(0xffeaf2ec, 12));
            View content;
            if (receipt.text == null && !receipt.localPath.isEmpty() &&
                receipt.fileName.toLowerCase(java.util.Locale.ROOT).matches(".*\\.(png|jpe?g|webp|gif|bmp|heic|heif)$")) {
                ImageView image = new ImageView(context);
                image.setScaleType(ImageView.ScaleType.CENTER_CROP);
                image.setContentDescription(receipt.fileName);
                image.setBackgroundColor(0xffdae7df);
                content = image;
                thumbnails.execute(() -> {
                    Bitmap bitmap = thumbnail(receipt.localPath, dp(160));
                    main.post(() -> { if (image.getParent() != null && bitmap != null) image.setImageBitmap(bitmap); });
                });
            } else {
                TextView text = label(receipt.text == null ? "▧\n" + receipt.fileName : receipt.text, 14, 0xff24372e);
                text.setMaxLines(3);
                text.setEllipsize(android.text.TextUtils.TruncateAt.END);
                content = text;
            }
            card.addView(content, new LinearLayout.LayoutParams(-1, 0, 1));
            LinearLayout footer = new LinearLayout(context);
            footer.setGravity(Gravity.CENTER_VERTICAL);
            TextView source = label(receipt.source, 10, 0xff7c8d83);
            source.setSingleLine(true); source.setEllipsize(android.text.TextUtils.TruncateAt.END);
            footer.addView(source, new LinearLayout.LayoutParams(0, dp(24), 1));
            if (receipt.text != null) footer.addView(control("复制", "复制", () -> actions.copy(receipt.id)),
                new LinearLayout.LayoutParams(dp(40), dp(24)));
            card.addView(footer);
            card.setOnClickListener(view -> actions.open(receipt.id));
            card.setOnLongClickListener(view -> {
                if (receipt.text == null && receipt.localPath.isEmpty()) return false;
                try {
                    return DockCoordinator.startDrag(view, receipt.text == null ? receipt.localPath : null,
                        receipt.text, receipt.fileName.isEmpty() ? "GlobalSend" : receipt.fileName);
                } catch (Exception unavailable) { return false; }
            });
            LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(side, side);
            size.rightMargin = dp(6);
            row.addView(card, size);
        }
        scroll.scrollTo(0, 0);
    }

    private void installMove(View handle, boolean resize) {
        handle.setOnTouchListener((view, event) -> {
            if (event.getActionMasked() == MotionEvent.ACTION_DOWN) {
                downX = event.getRawX(); downY = event.getRawY();
                startX = layout.x; startY = layout.y;
                startWidth = layout.width; startHeight = layout.height;
                return true;
            }
            if (event.getActionMasked() == MotionEvent.ACTION_MOVE) {
                int dx = Math.round(event.getRawX() - downX), dy = Math.round(event.getRawY() - downY);
                Rect bounds = availableBounds();
                if (resize) {
                    layout.width = clamp(startWidth + dx, dp(220), Math.min(dp(400), bounds.width() - dp(16)));
                    layout.height = clamp(startHeight + dy, dp(140), Math.min(dp(260), bounds.height() - dp(16)));
                } else { layout.x = startX + dx; layout.y = startY + dy; }
                layout.x = clamp(layout.x, bounds.left, bounds.right - layout.width);
                layout.y = clamp(layout.y, bounds.top, bounds.bottom - layout.height);
                windows.updateViewLayout(root, layout);
                if (resize) render();
                return true;
            }
            return true;
        });
    }

    private void dismiss() {
        Map<String, String> versions = new LinkedHashMap<>();
        for (ReceiveNotifications.Receipt receipt : items.values()) versions.put(receipt.id, receipt.version);
        long closedGeneration = generation;
        hide();
        actions.dismiss(versions, closedGeneration);
    }
    @Override public void hide() {
        lastHideRevision = ++visibilityRevision;
        hideWhenReady(lastHideRevision);
    }

    private void hideWhenReady(long request) {
        if (request != lastHideRevision) return;
        final View exportingRoot = root;
        if (exportingRoot != null && DockCoordinator.afterExportFrom(exportingRoot, () -> {
            hideWhenReady(request);
        })) return;
        if (root != null) {
            final View leaving = root;
            final WindowManager.LayoutParams leavingLayout = layout;
            final boolean registered = rootAdded;
            root = null; row = null; scroll = null; count = null; layout = null;
            rootAdded = false;
            leaving.animate().cancel();
            if (registered && leaving.isAttachedToWindow()) {
                leavingLayout.flags |= WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE;
                windows.updateViewLayout(leaving, leavingLayout);
                leaving.animate().alpha(0).translationX(dp(20)).scaleX(.96f).scaleY(.96f)
                    .setDuration(150).start();
                // Cleanup must not depend on ViewPropertyAnimator's end action:
                // cancellation or a late first-frame callback can suppress it.
                main.postDelayed(() -> {
                    windows.removeViewImmediate(leaving);
                }, 160);
            } else if (registered) { windows.removeViewImmediate(leaving); }
        }
        items.clear();
    }
    private Rect availableBounds() {
        if (Build.VERSION.SDK_INT >= 30) {
            android.view.WindowMetrics metrics = windows.getMaximumWindowMetrics();
            Rect bounds = new Rect(metrics.getBounds());
            android.graphics.Insets insets = metrics.getWindowInsets().getInsetsIgnoringVisibility(
                WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
            bounds.inset(insets.left, insets.top, insets.right, insets.bottom);
            return bounds;
        }
        android.util.DisplayMetrics metrics = context.getResources().getDisplayMetrics();
        return new Rect(0, 0, metrics.widthPixels, metrics.heightPixels);
    }
    private TextView control(String text, String description, Runnable action) {
        TextView button = label(text, 13, 0xff126e53);
        button.setGravity(Gravity.CENTER); button.setContentDescription(description);
        button.setOnClickListener(view -> action.run());
        return button;
    }
    private TextView label(String value, int sp, int color) {
        TextView text = new TextView(context); text.setText(value); text.setTextSize(sp); text.setTextColor(color);
        text.setGravity(Gravity.CENTER_VERTICAL);
        return text;
    }
    private GradientDrawable shape(int color, int radius) {
        GradientDrawable drawable = new GradientDrawable(); drawable.setColor(color); drawable.setCornerRadius(dp(radius));
        return drawable;
    }
    private int dp(int value) { return Math.round(value * context.getResources().getDisplayMetrics().density); }
    private static int clamp(int value, int min, int max) { return Math.max(Math.min(min, max), Math.min(value, max)); }
    private Bitmap thumbnail(String path, int size) {
        try {
            BitmapFactory.Options options = new BitmapFactory.Options();
            options.inJustDecodeBounds = true;
            try (java.io.InputStream input = open(path)) { BitmapFactory.decodeStream(input, null, options); }
            options.inSampleSize = 1;
            while (options.outWidth / options.inSampleSize > size * 2 || options.outHeight / options.inSampleSize > size * 2)
                options.inSampleSize *= 2;
            options.inJustDecodeBounds = false;
            try (java.io.InputStream input = open(path)) { return BitmapFactory.decodeStream(input, null, options); }
        } catch (java.io.IOException | RuntimeException unavailable) { return null; }
    }
    private java.io.InputStream open(String path) throws java.io.IOException {
        return AndroidReadSource.openStream(context, path);
    }
}
