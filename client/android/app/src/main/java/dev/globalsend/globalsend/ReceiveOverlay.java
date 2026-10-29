package dev.globalsend.globalsend;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.InsetDrawable;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.DragEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.ViewTreeObserver;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.widget.HorizontalScrollView;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.ArrayList;
import java.util.List;

/** A small independent OS overlay. No Activity, backdrop, or full-display touch surface. */
final class ReceiveOverlay implements ReceiveNotifications.Presenter {
    private static java.lang.ref.WeakReference<ReceiveOverlay> current = new java.lang.ref.WeakReference<>(null);
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
    private FrameLayout root;
    private LinearLayout row, expanded;
    private HorizontalScrollView scroll;
    private TextView count;
    private WindowManager.LayoutParams layout;
    private long generation;
    private boolean rootAdded;
    private long visibilityRevision, lastHideRevision;
    private float downX, downY;
    private int startX, startY, startWidth, startHeight;
    private ReceiveAppearance appearance;
    private final TemporaryShelf shelf;
    private LinearLayout header;
    private TextView shelfTab, handle, resize;
    private android.view.GestureDetector contentGestures;
    private Runnable pendingOpen;
    private boolean doubleTapGesture;
    private boolean collapsed, shelfVisible, edgeRight = true;
    private int expandedWidth, expandedHeight;
    private android.animation.ValueAnimator geometry;
    private Runnable dragExpand;
    private int importing;
    private android.os.FileObserver appearanceChanges;
    private final android.content.ComponentCallbacks configurationChanges = new android.content.ComponentCallbacks() {
        @Override public void onConfigurationChanged(android.content.res.Configuration next) { main.post(() -> shelfChanged()); }
        @Override public void onLowMemory() { }
    };
    private final Runnable countdown = new Runnable() {
        @Override public void run() {
            if (root == null || shelf.removalSeconds() == 0) return;
            updateLabels(); main.postDelayed(this, 100);
        }
    };
    private static final java.util.concurrent.ExecutorService thumbnails =
        java.util.concurrent.Executors.newSingleThreadExecutor();

    ReceiveOverlay(Context context, Actions actions) {
        this.context = context;
        this.actions = actions;
        windows = context.getSystemService(WindowManager.class);
        shelf = new TemporaryShelf(context, this::shelfChanged);
        current = new java.lang.ref.WeakReference<>(this);
    }

    static void openShelf() {
        ReceiveOverlay overlay = current.get();
        if (overlay == null) throw new IllegalStateException("暂存坞尚未就绪");
        if (!android.provider.Settings.canDrawOverlays(overlay.context)) throw new IllegalStateException("请先允许悬浮窗权限");
        overlay.shelfVisible = true;
        if (overlay.root == null) {
            overlay.create(); overlay.render();
            View appearing = overlay.root;
            appearing.post(() -> {
                if (overlay.root == appearing) appearing.animate().translationX(0).alpha(1).scaleX(1).scaleY(1)
                    .setDuration(180).setInterpolator(new android.view.animation.DecelerateInterpolator()).start();
            });
        } else { overlay.setCollapsed(false); overlay.render(); }
    }
    static void closeShelf() {
        ReceiveOverlay overlay=current.get();
        if(overlay==null)return;
        overlay.context.getSharedPreferences("received-popup-settings",Context.MODE_PRIVATE).edit().putBoolean("enabled",false).apply();
        overlay.dismiss();
    }

    @Override public void foreground() {
        // A persistent shelf stays reachable while the user moves between apps.
        // Received records are still shown in the main app, not duplicated there.
        if (root != null) setCollapsed(true);
    }

    private Map<String, ReceiveNotifications.Receipt> displayed() { return shelfVisible ? shelf.items : items; }

    private void shelfChanged() {
        if (root == null) return;
        if (DockCoordinator.afterExportFrom(root, this::shelfChanged)) return;
        render();
        main.removeCallbacks(countdown);
        if (shelf.removalSeconds() > 0) main.post(countdown);
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
            if (newItem && !collapsed) shelfVisible = false;
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
        appearance = ReceiveAppearance.load(context);
        rootAdded = false;
        root = new FrameLayout(context) {
            private boolean cancelTap;
            @Override public boolean dispatchTouchEvent(MotionEvent event) {
                if(event.getActionMasked()==MotionEvent.ACTION_DOWN)doubleTapGesture=false;
                if(contentGestures!=null) {
                    if(isContentArea(event))contentGestures.onTouchEvent(event);
                    else if(event.getActionMasked()==MotionEvent.ACTION_DOWN) {
                        MotionEvent cancel=MotionEvent.obtain(event);cancel.setAction(MotionEvent.ACTION_CANCEL);
                        contentGestures.onTouchEvent(cancel);cancel.recycle();
                    }
                }
                if(doubleTapGesture) {
                    if(event.getActionMasked()==MotionEvent.ACTION_UP || event.getActionMasked()==MotionEvent.ACTION_CANCEL)doubleTapGesture=false;
                    return true;
                }
                if (cancelTap && event.getActionMasked() == MotionEvent.ACTION_UP) {
                    MotionEvent cancel = MotionEvent.obtain(event);
                    cancel.setAction(MotionEvent.ACTION_CANCEL);
                    super.dispatchTouchEvent(cancel); cancel.recycle();
                    cancelTap = false;
                    return true;
                }
                if (event.getActionMasked() == MotionEvent.ACTION_CANCEL) cancelTap = false;
                if (event.getActionMasked() == MotionEvent.ACTION_DOWN && shelf.cancelRemoval()) {
                    main.removeCallbacks(countdown); refreshPendingStyles(); updateLabels();
                    cancelTap = true;
                    // Deliver DOWN/MOVE so a long press can still start a system
                    // drag. Only suppress the short tap's UP/click.
                }
                return super.dispatchTouchEvent(event);
            }
        };
        contentGestures=new android.view.GestureDetector(context,new android.view.GestureDetector.SimpleOnGestureListener() {
            @Override public boolean onDown(MotionEvent event) { return true; }
            @Override public boolean onDoubleTap(MotionEvent event) {
                doubleTapGesture=true; cancelPendingOpen();
                android.content.Intent intent=context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
                if(intent!=null)context.startActivity(intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK | android.content.Intent.FLAG_ACTIVITY_REORDER_TO_FRONT));
                return true;
            }
        });
        contentGestures.setIsLongpressEnabled(false);
        root.setBackground(shape(glass(appearance.surface,0x99), 18));
        root.setClipToOutline(true);
        root.setElevation(dp(8));
        root.setAlpha(0); root.setTranslationX(dp(20));
        root.setScaleX(.96f); root.setScaleY(.96f);
        expanded = new LinearLayout(context);
        expanded.setOrientation(LinearLayout.VERTICAL);
        expanded.setPadding(dp(6), dp(2), dp(6), dp(4));
        root.addView(expanded);
        header = new MoveHeader(context);
        header.setGravity(Gravity.CENTER_VERTICAL);
        count = control("", "接收", () -> { shelfVisible = false; render(); });
        count.setCompoundDrawablesRelativeWithIntrinsicBounds(0,0,R.drawable.ic_shelf_inbox,0);
        count.setCompoundDrawablePadding(dp(4));
        count.setSingleLine(true);
        header.addView(count, new LinearLayout.LayoutParams(0, dp(30), 1));
        shelfTab = control("", "暂存", () -> { shelfVisible = true; render(); });
        shelfTab.setCompoundDrawablesRelativeWithIntrinsicBounds(0,0,R.drawable.ic_shelf_folder,0);
        shelfTab.setCompoundDrawablePadding(dp(4));
        header.addView(shelfTab, new LinearLayout.LayoutParams(0, dp(30), 1));
        View all = icon(R.drawable.ic_drag_all, "全部拖出");
        all.setOnLongClickListener(view -> export(view, new ArrayList<>(displayed().values())));
        header.addView(all, new LinearLayout.LayoutParams(dp(30), dp(30)));
        expanded.addView(header);
        scroll = new HorizontalScrollView(context);
        scroll.setHorizontalScrollBarEnabled(false);
        row = new LinearLayout(context);
        row.setOrientation(LinearLayout.HORIZONTAL);
        scroll.addView(row, new HorizontalScrollView.LayoutParams(-2, -1));
        expanded.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        // A small bottom grip changes the actual OS window, not a full-screen wrapper.
        resize = label("⌟", 12, appearance.muted);
        resize.setGravity(Gravity.RIGHT);
        resize.setContentDescription("拖动调整大小");
        installMove(resize, true);
        expanded.addView(resize, new LinearLayout.LayoutParams(-1, dp(12)));
        handle = label("", 10, appearance.accent);
        handle.setGravity(Gravity.CENTER); handle.setContentDescription("展开文件暂存坞");
        handle.setOnClickListener(view -> setCollapsed(false));
        installEdgeMove(handle);
        handle.setVisibility(View.GONE);
        root.addView(handle, new FrameLayout.LayoutParams(dp(18), dp(72), Gravity.CENTER_VERTICAL | Gravity.RIGHT));
        root.setOnDragListener((view, event) -> receiveDrop(event));
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
        expandedWidth = layout.width; expandedHeight = layout.height; collapsed = false;
        expanded.setLayoutParams(new FrameLayout.LayoutParams(expandedWidth, expandedHeight));
        windows.addView(root, layout);
        rootAdded = true;
        context.registerComponentCallbacks(configurationChanges);
        appearanceChanges = new android.os.FileObserver(context.getFilesDir().getPath(), android.os.FileObserver.CLOSE_WRITE | android.os.FileObserver.MOVED_TO) {
            @Override public void onEvent(int event, String path) {
                if ("appearance.json".equals(path)) main.post(() -> shelfChanged());
            }
        };
        appearanceChanges.startWatching();
    }

    private void render() {
        appearance = ReceiveAppearance.load(context);
        root.setBackground(shape(collapsed ? 0 : glass(appearance.surface,0x99), 18));
        for (int i=0;i<header.getChildCount();i++) {
            View child = header.getChildAt(i);
            if (child instanceof TextView) ((TextView)child).setTextColor(appearance.accent);
            if (child instanceof ImageView) ((ImageView)child).setColorFilter(appearance.accent);
        }
        resize.setTextColor(appearance.muted);
        styleHandle();
        expanded.setLayoutParams(new FrameLayout.LayoutParams(expandedWidth, expandedHeight,
            Gravity.TOP | (edgeRight ? Gravity.LEFT : Gravity.RIGHT)));
        handle.setLayoutParams(new FrameLayout.LayoutParams(dp(18), dp(72),
            Gravity.CENTER_VERTICAL | (edgeRight ? Gravity.RIGHT : Gravity.LEFT)));
        row.removeAllViews();
        updateLabels();
        int side = Math.max(1, expandedHeight - dp(48));
        if (displayed().isEmpty()) {
            TextView empty = label(shelfVisible ? "拖入文件、图片或文字" : "暂无接收内容", 13, appearance.muted);
            empty.setGravity(Gravity.CENTER);
            row.addView(empty, new LinearLayout.LayoutParams(expandedWidth - dp(12), side));
        }
        for (ReceiveNotifications.Receipt receipt : displayed().values()) {
            LinearLayout card = new LinearLayout(context);
            card.setOrientation(LinearLayout.VERTICAL);
            card.setTag(receipt);
            card.setPadding(dp(8), dp(6), dp(8), dp(4));
            card.setBackground(shape(glass(appearance.soft,0xb3), 12));
            boolean pending = shelfVisible && shelf.pendingRemoval(receipt.id);
            if (pending) card.setBackground(shape(pendingColor(), 12));
            View content;
            if (receipt.text == null && !receipt.localPath.isEmpty() &&
                receipt.fileName.toLowerCase(java.util.Locale.ROOT).matches(".*\\.(png|jpe?g|webp|gif|bmp|heic|heif)$")) {
                ImageView image = new ImageView(context);
                image.setScaleType(ImageView.ScaleType.CENTER_CROP);
                image.setContentDescription(receipt.fileName);
                image.setBackgroundColor(appearance.field);
                content = image;
                thumbnails.execute(() -> {
                    Bitmap bitmap = thumbnail(receipt.localPath, dp(160));
                    main.post(() -> { if (image.getParent() != null && bitmap != null) image.setImageBitmap(bitmap); });
                });
            } else {
                TextView text = label(receipt.text == null ? "▧\n" + receipt.fileName : receipt.text, 14, appearance.ink);
                text.setMaxLines(3);
                text.setEllipsize(android.text.TextUtils.TruncateAt.END);
                content = text;
            }
            FrameLayout preview = new FrameLayout(context);
            preview.addView(content, new FrameLayout.LayoutParams(-1,-1));
            TextView remove = control("×", "移除", () -> remove(receipt));
            remove.setBackground(shape(glass(appearance.surface,0xb3), 12));
            preview.addView(remove,new FrameLayout.LayoutParams(dp(28),dp(28),Gravity.TOP|Gravity.RIGHT));
            card.addView(preview, new LinearLayout.LayoutParams(-1, 0, 1));
            LinearLayout footer = new LinearLayout(context);
            footer.setGravity(Gravity.CENTER_VERTICAL);
            TextView source = label(receipt.source, 10, appearance.muted);
            source.setSingleLine(true); source.setEllipsize(android.text.TextUtils.TruncateAt.END);
            footer.addView(source, new LinearLayout.LayoutParams(0, dp(24), 1));
            View deleting = icon(android.R.drawable.ic_menu_delete,"3秒后移除，轻点取消");
            deleting.setTag("pending-removal"); deleting.setVisibility(pending ? View.VISIBLE : View.GONE);
            ((ImageView)deleting).setColorFilter(0xffd84c53);
            footer.addView(deleting,new LinearLayout.LayoutParams(dp(24),dp(24)));
            if (receipt.text != null) footer.addView(control("复制", "复制", () -> copy(receipt)),
                new LinearLayout.LayoutParams(dp(40), dp(24)));
            card.addView(footer);
            card.setOnClickListener(view -> queueOpen(receipt));
            card.setOnLongClickListener(view -> {
                return export(view, java.util.Collections.singletonList(receipt));
            });
            LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(side, side);
            size.rightMargin = dp(6);
            row.addView(card, size);
        }
        if (!displayed().isEmpty()) {
            LinearLayout clear = new LinearLayout(context);
            clear.setGravity(Gravity.CENTER); clear.setOrientation(LinearLayout.VERTICAL);
            clear.setBackground(shape(glass(appearance.soft,0xb3),12)); clear.setContentDescription("清空当前列表");
            TextView clearIcon=label("×",30,appearance.accent);
            clearIcon.setGravity(Gravity.CENTER);
            clear.addView(clearIcon,new LinearLayout.LayoutParams(dp(40),dp(40)));
            TextView clearLabel=label("清空",12,appearance.muted);clearLabel.setGravity(Gravity.CENTER);
            clear.addView(clearLabel);
            clear.setOnClickListener(view -> clearDisplayed());
            row.addView(clear,new LinearLayout.LayoutParams(side,side));
        }
        scroll.scrollTo(0, 0);
    }

    private int pendingColor() {
        return android.graphics.Color.luminance(appearance.surface) < .3f ? 0xff542b32 : 0xffffe4e6;
    }
    private int glass(int color,int alpha) { return (color&0x00ffffff)|(alpha<<24); }
    private void styleHandle() {
        android.graphics.drawable.LayerDrawable layers=new android.graphics.drawable.LayerDrawable(new android.graphics.drawable.Drawable[]{
            new InsetDrawable(shape(glass(appearance.surface,0x33),6),dp(edgeRight?6:0),dp(12),dp(edgeRight?0:6),dp(12)),
            new InsetDrawable(shape(glass(appearance.accent,0x80),2),dp(edgeRight?10:4),dp(24),dp(edgeRight?4:10),dp(24))
        });
        layers.setPaddingMode(android.graphics.drawable.LayerDrawable.PADDING_MODE_STACK);
        handle.setBackground(layers);
    }
    private boolean isContentArea(MotionEvent event) {
        if(collapsed || scroll==null || !scroll.isShown())return false;
        return hits(scroll,event) && !hitsAction(scroll,event);
    }
    private boolean hits(View view,MotionEvent event) {
        Rect bounds=new Rect();view.getDrawingRect(bounds);root.offsetDescendantRectToMyCoords(view,bounds);
        return bounds.contains((int)event.getX(),(int)event.getY());
    }
    private boolean hitsAction(View view,MotionEvent event) {
        if(!hits(view,event))return false;
        if((view instanceof TextView && view.isClickable()) || "清空当前列表".contentEquals(view.getContentDescription()==null?"":view.getContentDescription()))return true;
        if(view instanceof android.view.ViewGroup) {
            android.view.ViewGroup group=(android.view.ViewGroup)view;
            for(int i=0;i<group.getChildCount();i++)if(hitsAction(group.getChildAt(i),event))return true;
        }
        return false;
    }
    private void cancelPendingOpen() {
        if(pendingOpen!=null)main.removeCallbacks(pendingOpen);
        pendingOpen=null;
    }
    private void queueOpen(ReceiveNotifications.Receipt receipt) {
        cancelPendingOpen();View owner=root;
        pendingOpen=() -> {pendingOpen=null;if(root==owner)open(receipt);};
        main.postDelayed(pendingOpen,ViewConfiguration.getDoubleTapTimeout());
    }
    private void refreshPendingStyles() {
        if(row==null)return;
        for(int i=0;i<row.getChildCount();i++) {
            View card=row.getChildAt(i);
            if(!(card.getTag() instanceof ReceiveNotifications.Receipt))continue;
            boolean pending=shelfVisible && shelf.pendingRemoval(((ReceiveNotifications.Receipt)card.getTag()).id);
            card.setBackground(shape(pending ? pendingColor() : glass(appearance.soft,0xb3),12));
            card.findViewWithTag("pending-removal").setVisibility(pending ? View.VISIBLE : View.GONE);
        }
    }
    private void renderKeepingScroll() {
        int offset=scroll.getScrollX(); render();
        HorizontalScrollView owner=scroll;
        owner.post(() -> { if(scroll==owner)owner.scrollTo(offset,0); });
    }
    private void remove(ReceiveNotifications.Receipt receipt) {
        if (shelfVisible) shelf.remove(receipt.id);
        else {
            items.remove(receipt.id); renderKeepingScroll();
            actions.dismiss(java.util.Collections.singletonMap(receipt.id,receipt.version),generation);
        }
    }
    private void clearDisplayed() {
        if (shelfVisible) shelf.clear();
        else {
            Map<String,String> versions=new LinkedHashMap<>();
            for(ReceiveNotifications.Receipt receipt:items.values())versions.put(receipt.id,receipt.version);
            items.clear(); render(); actions.dismiss(versions,generation);
        }
    }

    private void updateLabels() {
        if (root == null) return;
        int remaining = shelf.removalSeconds();
        count.setText(String.valueOf(items.size())); shelfTab.setText(String.valueOf(shelf.items.size()));
        count.setContentDescription("接收 " + items.size() + " 项");
        shelfTab.setContentDescription("暂存 " + shelf.items.size() + " 项");
        count.setTextColor(shelfVisible ? appearance.muted : appearance.accent);
        shelfTab.setTextColor(shelfVisible ? appearance.accent : appearance.muted);
        count.setCompoundDrawableTintList(android.content.res.ColorStateList.valueOf(count.getCurrentTextColor()));
        shelfTab.setCompoundDrawableTintList(android.content.res.ColorStateList.valueOf(shelfTab.getCurrentTextColor()));
        count.setTypeface(null, shelfVisible ? 0 : 1); shelfTab.setTypeface(null, shelfVisible ? 1 : 0);
        handle.setText("");
        handle.setContentDescription("展开文件暂存坞，接收 " + items.size() + " 项，暂存 " + shelf.items.size() + " 项");
        if (remaining > 0) shelfTab.setContentDescription("暂存 " + shelf.items.size() + " 项，" + remaining + " 秒后移除，轻点取消");
        else if (importing > 0) shelfTab.setContentDescription("暂存 " + shelf.items.size() + " 项，正在导入");
    }

    private boolean export(View source, List<ReceiveNotifications.Receipt> selection) {
        List<String> paths = new ArrayList<>(), texts = new ArrayList<>();
        List<ReceiveNotifications.Receipt> staged = new ArrayList<>();
        for (ReceiveNotifications.Receipt item : selection) {
            if (item.text != null) texts.add(item.text);
            else if (!item.localPath.isEmpty()) paths.add(item.localPath);
            if (shelf.items.get(item.id) == item) staged.add(item);
        }
        if (paths.isEmpty() && texts.isEmpty()) return false;
        shelf.cancelRemoval();
        cancelPendingOpen();
        main.removeCallbacks(countdown); refreshPendingStyles(); updateLabels();
        try {
            return DockCoordinator.startDrag(source, paths, texts, (paths.size() + texts.size()) + " 项", accepted -> {
                shelf.exported(staged, accepted);
            });
        } catch (Exception unavailable) {
            android.util.Log.w("GlobalSend", "Cannot export temporary shelf drag", unavailable);
            android.widget.Toast.makeText(context, "无法拖出，请重试", android.widget.Toast.LENGTH_SHORT).show(); return false;
        }
    }

    @SuppressWarnings("unchecked")
    private boolean receiveDrop(DragEvent event) {
        switch (event.getAction()) {
            case DragEvent.ACTION_DRAG_STARTED:
                cancelPendingOpen();
                if (shelf.cancelRemoval()) { main.removeCallbacks(countdown); shelfChanged(); }
                return event.getClipDescription() != null;
            case DragEvent.ACTION_DRAG_ENTERED:
                if (collapsed) {
                    dragExpand = () -> { dragExpand = null; setCollapsed(false); };
                    main.postDelayed(dragExpand, 250);
                }
                root.setBackground(shape(glass(appearance.soft,0x99), 18)); return true;
            case DragEvent.ACTION_DRAG_EXITED:
            case DragEvent.ACTION_DRAG_ENDED:
                if (dragExpand != null) main.removeCallbacks(dragExpand);
                dragExpand = null;
                if (root != null) root.setBackground(shape(collapsed ? 0 : glass(appearance.surface,0x99), 18));
                return true;
            case DragEvent.ACTION_DROP:
                if (dragExpand != null) main.removeCallbacks(dragExpand);
                dragExpand = null;
                importing++; shelfVisible = true; updateLabels();
                boolean accepted;
                try { accepted = DockCoordinator.importToShelf(event, content -> {
                    importing--;
                    shelfVisible = true;
                    shelf.add((List<String>)content.get("paths"), (List<String>)content.get("texts"),
                        (Map<String, String>)content.getOrDefault("directoryNames", java.util.Collections.emptyMap()));
                    if (root != null) setCollapsed(false);
                    if (content.containsKey("error")) android.widget.Toast.makeText(context, "部分内容无法读取，请重新拖入", android.widget.Toast.LENGTH_LONG).show();
                }); } catch (RuntimeException unavailable) {
                    accepted = false;
                    android.widget.Toast.makeText(context, "无法读取拖入内容，请重试", android.widget.Toast.LENGTH_SHORT).show();
                }
                if (!accepted) { importing--; updateLabels(); }
                return accepted;
            default: return true;
        }
    }

    private void copy(ReceiveNotifications.Receipt receipt) {
        if (!receipt.id.startsWith("shelf:")) { actions.copy(receipt.id); return; }
        context.getSystemService(android.content.ClipboardManager.class)
            .setPrimaryClip(android.content.ClipData.newPlainText("GlobalSend", receipt.text));
    }
    private void open(ReceiveNotifications.Receipt receipt) {
        if (!receipt.id.startsWith("shelf:")) { actions.open(receipt.id); return; }
        if (receipt.text != null) { copy(receipt); return; }
        try {
            android.net.Uri uri = receipt.localPath.startsWith("content://") ? android.net.Uri.parse(receipt.localPath) :
                DockShareProvider.register(context, new java.io.File(receipt.localPath), receipt.fileName);
            String type = context.getContentResolver().getType(uri);
            context.startActivity(new android.content.Intent(android.content.Intent.ACTION_VIEW).setDataAndType(uri, type == null ? "application/octet-stream" : type)
                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK | android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION));
        } catch (Exception unavailable) { android.widget.Toast.makeText(context, "无法打开文件", android.widget.Toast.LENGTH_SHORT).show(); }
    }

    /** The whole title row moves the window; taps and stationary long presses
     * still belong to its controls, including the bulk system-drag button. */
    private final class MoveHeader extends LinearLayout {
        private final int slop;
        private float initialTouchX, initialTouchY;
        private int initialWindowX, initialWindowY;
        private boolean tracking, moving;

        MoveHeader(Context context) {
            super(context);
            slop = ViewConfiguration.get(context).getScaledTouchSlop();
            setClickable(true);
        }
        @Override public boolean onInterceptTouchEvent(MotionEvent event) {
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    initialTouchX = event.getRawX(); initialTouchY = event.getRawY();
                    initialWindowX = layout.x; initialWindowY = layout.y;
                    tracking = true; moving = false;
                    return false;
                case MotionEvent.ACTION_MOVE:
                    if (tracking && Math.hypot(event.getRawX() - initialTouchX,
                            event.getRawY() - initialTouchY) > slop) {
                        moving = true;
                        moveWindow(event);
                        return true;
                    }
                    return false;
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_CANCEL:
                    tracking = false; moving = false;
                    return false;
                default: return false;
            }
        }
        @Override public boolean onTouchEvent(MotionEvent event) {
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN: return true;
                case MotionEvent.ACTION_MOVE:
                    if (!tracking) return false;
                    if (!moving && Math.hypot(event.getRawX() - initialTouchX,
                            event.getRawY() - initialTouchY) <= slop) return true;
                    moving = true;
                    moveWindow(event);
                    return true;
                case MotionEvent.ACTION_UP:
                    boolean dragged = moving;
                    tracking = false; moving = false;
                    if (!dragged) { performClick(); return true; }
                    Rect work = availableBounds();
                    setCollapsed(layout.x <= work.left + dp(16) || layout.x + layout.width >= work.right - dp(16));
                    return true;
                case MotionEvent.ACTION_CANCEL:
                    tracking = false; moving = false;
                    return true;
                default: return super.onTouchEvent(event);
            }
        }
        private void moveWindow(MotionEvent event) {
            stopGeometry();
            Rect bounds = availableBounds();
            layout.x = clamp(initialWindowX + Math.round(event.getRawX() - initialTouchX), bounds.left, bounds.right - layout.width);
            layout.y = clamp(initialWindowY + Math.round(event.getRawY() - initialTouchY), bounds.top, bounds.bottom - layout.height);
            windows.updateViewLayout(root, layout);
        }
    }

    private void installMove(View handle, boolean resize) {
        handle.setOnTouchListener((view, event) -> {
            if (event.getActionMasked() == MotionEvent.ACTION_DOWN) {
                downX = event.getRawX(); downY = event.getRawY();
                startX = layout.x; startY = layout.y;
                startWidth = layout.width; startHeight = layout.height;
                stopGeometry();
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
                if (resize) { expandedWidth = layout.width; expandedHeight = layout.height; render(); }
                return true;
            }
            if (!resize && event.getActionMasked() == MotionEvent.ACTION_UP) {
                if (Math.abs(event.getRawX() - downX) < dp(6) && Math.abs(event.getRawY() - downY) < dp(6)) {
                    view.performClick(); return true;
                }
                Rect bounds = availableBounds();
                if (layout.x <= bounds.left + dp(16) || layout.x + layout.width >= bounds.right - dp(16)) setCollapsed(true);
            }
            if (resize && event.getActionMasked() == MotionEvent.ACTION_UP) setCollapsed(false);
            return true;
        });
    }

    private void installEdgeMove(View view) {
        view.setOnTouchListener((handle, event) -> {
            if (event.getActionMasked() == MotionEvent.ACTION_DOWN) {
                stopGeometry();
                downX = event.getRawX(); downY = event.getRawY(); startY = layout.y;
                return true;
            }
            if (event.getActionMasked() == MotionEvent.ACTION_MOVE) {
                int dx = Math.round(event.getRawX() - downX), dy = Math.round(event.getRawY() - downY);
                if ((edgeRight ? -dx : dx) > dp(28)) { setCollapsed(false); return true; }
                Rect bounds = availableBounds();
                layout.y = clamp(startY + dy, bounds.top, bounds.bottom - layout.height);
                windows.updateViewLayout(root, layout); return true;
            }
            if (event.getActionMasked() == MotionEvent.ACTION_UP &&
                    Math.abs(event.getRawY() - downY) < dp(6) && Math.abs(event.getRawX() - downX) < dp(6)) handle.performClick();
            else if (event.getActionMasked() == MotionEvent.ACTION_UP) setCollapsed(true);
            return true;
        });
    }

    void setCollapsed(boolean value) {
        if (root == null || collapsed == value && geometry != null) return;
        if (DockCoordinator.afterExportFrom(root, () -> setCollapsed(value))) return;
        if (collapsed == value && geometry == null && layout.width == (value ? dp(18) : expandedWidth)
                && layout.height == (value ? dp(72) : expandedHeight)) {
            finishGeometry(value); return;
        }
        stopGeometry();
        Rect bounds = availableBounds();
        if (value && !collapsed) {
            edgeRight = layout.x + layout.width / 2 >= bounds.centerX();
        }
        collapsed = value;
        styleHandle();
        int width = value ? dp(18) : expandedWidth, height = value ? dp(72) : expandedHeight;
        int x = edgeRight ? bounds.right - width : bounds.left;
        int y = clamp(layout.y, bounds.top, bounds.bottom - height);
        if (layout.width == width && layout.height == height && layout.x == x && layout.y == y) {
            finishGeometry(value); return;
        }
        expanded.setLayoutParams(new FrameLayout.LayoutParams(expandedWidth, expandedHeight,
            Gravity.TOP | (edgeRight ? Gravity.LEFT : Gravity.RIGHT)));
        handle.setLayoutParams(new FrameLayout.LayoutParams(dp(18), dp(72),
            Gravity.CENTER_VERTICAL | (edgeRight ? Gravity.RIGHT : Gravity.LEFT)));
        float initialPanelAlpha = expanded.getVisibility() == View.VISIBLE ? expanded.getAlpha() : 0;
        float initialHandleAlpha = handle.getVisibility() == View.VISIBLE ? handle.getAlpha() : 0;
        expanded.setVisibility(View.VISIBLE); handle.setVisibility(View.VISIBLE);
        handle.setEnabled(false); handle.setClickable(false);
        int initialX = layout.x, initialY = layout.y, initialWidth = layout.width, initialHeight = layout.height;
        View owner = root;
        android.animation.ValueAnimator moving = android.animation.ValueAnimator.ofFloat(0, 1);
        geometry = moving;
        moving.setDuration(240); moving.setInterpolator(new android.view.animation.DecelerateInterpolator(1.5f));
        moving.addUpdateListener(animation -> {
            if (root != owner || geometry != moving) return;
            float t = (Float)animation.getAnimatedValue();
            layout.x = Math.round(initialX + (x - initialX) * t); layout.y = Math.round(initialY + (y - initialY) * t);
            layout.width = Math.round(initialWidth + (width - initialWidth) * t); layout.height = Math.round(initialHeight + (height - initialHeight) * t);
            float panelProgress = t;
            float handleProgress = t;
            expanded.setAlpha(initialPanelAlpha + ((value ? 0 : 1) - initialPanelAlpha) * panelProgress);
            handle.setAlpha(initialHandleAlpha + ((value ? 1 : 0) - initialHandleAlpha) * handleProgress);
            root.setBackground(shape(glass(appearance.surface,Math.round(0x99*(value ? 1-t : t))),18));
            root.setElevation(dp(8) + (dp(4) - dp(8)) * (value ? t : 1 - t));
            windows.updateViewLayout(root, layout);
        });
        moving.addListener(new android.animation.AnimatorListenerAdapter() {
            @Override public void onAnimationEnd(android.animation.Animator animation) {
                if (root != owner || geometry != moving) return;
                geometry = null; finishGeometry(value);
            }
        });
        updateLabels(); moving.start();
    }

    private void stopGeometry() {
        android.animation.ValueAnimator previous = geometry;
        geometry = null;
        if (previous != null) previous.cancel();
    }
    private void finishGeometry(boolean small) {
        expanded.setVisibility(small ? View.GONE : View.VISIBLE);
        handle.setVisibility(small ? View.VISIBLE : View.GONE);
        expanded.setAlpha(1); handle.setAlpha(1);
        handle.setEnabled(true); handle.setClickable(true);
        root.setBackground(shape(small ? 0 : glass(appearance.surface,0x99),18));
        root.setElevation(dp(small ? 4 : 8));
    }

    private View icon(int drawable, String description) {
        ImageView image = new ImageView(context);
        image.setImageResource(drawable); image.setColorFilter(appearance.accent);
        image.setPadding(dp(6), dp(6), dp(6), dp(6)); image.setContentDescription(description);
        return image;
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
            context.unregisterComponentCallbacks(configurationChanges);
            if (appearanceChanges != null) { appearanceChanges.stopWatching(); appearanceChanges = null; }
            stopGeometry();
            cancelPendingOpen();
            main.removeCallbacks(countdown);
            if (dragExpand != null) main.removeCallbacks(dragExpand);
            dragExpand = null;
            final View leaving = root;
            final WindowManager.LayoutParams leavingLayout = layout;
            final boolean registered = rootAdded;
            root = null; expanded = null; row = null; scroll = null; count = null; layout = null;
            header = null; handle = null; resize = null; shelfTab = null; contentGestures=null;
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
        TextView button = label(text, 13, appearance.accent);
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
