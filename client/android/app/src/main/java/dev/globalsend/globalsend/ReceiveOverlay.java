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
import android.view.Choreographer;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.VelocityTracker;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.ViewTreeObserver;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.widget.HorizontalScrollView;
import android.widget.OverScroller;
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
    private final OverScroller handleScroller;
    private VelocityTracker handleVelocity;
    private boolean dragInside;
    private final Runnable handleFling = new Runnable() {
        @Override public void run() {
            if(root==null || !collapsed)return;
            if(handleScroller.computeScrollOffset()) {
                layout.y=handleScroller.getCurrY();
                visualBounds=new Rect(layout.x,layout.y,layout.x+layout.width,layout.y+layout.height);
                windows.updateViewLayout(root,layout);
                root.postOnAnimation(this);
            } else savePlacement();
        }
    };
    interface Actions {
        void open(String id);
        void copy(String id);
        void dismiss(Map<String, String> versions, long generation);
    }
    private final Context context;
    private final WindowManager windows;
    private final Actions actions;
    private final android.content.SharedPreferences placement;
    private final LinkedHashMap<String, ReceiveNotifications.Receipt> items = new LinkedHashMap<>();
    private final Handler main = new Handler(Looper.getMainLooper());
    private FrameLayout root, surface;
    private LinearLayout row, expanded, rail;
    private HorizontalScrollView scroll;
    private HorizontalScrollView targetScroll;
    private LinearLayout targetRow;
    private ForwardDrag forwarding;
    private View hoveredTarget;
    private int targetScrollDirection;
    private float targetPointerX, targetPointerY;
    private float targetEdgeDepth, targetScrollVelocity, targetScrollOffset;
    private long targetScrollFrameNanos;
    private final Choreographer.FrameCallback targetAutoScroll = new Choreographer.FrameCallback() {
        @Override public void doFrame(long frameTimeNanos) {
            if(forwarding==null || targetScroll==null || targetScroll.getVisibility()!=View.VISIBLE || targetScrollDirection==0)return;
            if(targetScrollFrameNanos!=0) {
                float seconds=Math.min(.032f,(frameTimeNanos-targetScrollFrameNanos)*1e-9f);
                float ease=targetEdgeDepth*targetEdgeDepth*(3-2*targetEdgeDepth);
                float desired=targetScrollDirection*(dp(60)+dp(360)*ease);
                float difference=targetScrollVelocity-desired, decay=(float)Math.exp(-seconds/.04f);
                // Integrate the easing curve, not a fixed number of pixels per
                // callback. Motion remains the same on 60/90/120 Hz screens.
                targetScrollOffset+=desired*seconds+difference*.04f*(1-decay);
                targetScrollVelocity=desired+difference*decay;
                int maximum=Math.max(0,targetRow.getWidth()-targetScroll.getWidth()+targetScroll.getPaddingLeft()+targetScroll.getPaddingRight());
                targetScrollOffset=Math.max(0,Math.min(maximum,targetScrollOffset));
                int before=targetScroll.getScrollX();targetScroll.scrollTo(Math.round(targetScrollOffset),0);
                if(targetScroll.getScrollX()!=before)highlightTarget(targetPointerX,targetPointerY);
            }
            targetScrollFrameNanos=frameTimeNanos;
            Choreographer.getInstance().postFrameCallback(this);
        }
    };
    private static final class ForwardDrag {
        final List<String> paths,texts;
        final List<ReceiveNotifications.Receipt> staged;
        final String serverKey;
        boolean sentToDevice;
        ForwardDrag(List<String> paths,List<String> texts,List<ReceiveNotifications.Receipt> staged) {
            this.paths=paths;this.texts=texts;this.staged=staged;serverKey=DockCoordinator.sendServerKey();
        }
    }
    private TextView count;
    private WindowManager.LayoutParams layout;
    private long generation;
    private boolean rootAdded;
    private long visibilityRevision, lastHideRevision;
    private float downX, downY;
    private int startX, startY, startWidth, startHeight;
    private ReceiveAppearance appearance;
    private final TemporaryShelf shelf;
    private final RecentMediaSuggestions mediaSuggestions;
    private LinearLayout header;
    private TextView shelfTab, handle;
    private LinearLayout countGroup, shelfGroup;
    private ImageView countIcon, shelfIcon;
    private android.view.GestureDetector contentGestures;
    private Runnable pendingOpen;
    private boolean doubleTapGesture;
    private boolean collapsed, shelfVisible, edgeRight = true;
    private boolean appForeground;
    private boolean mainMediaActive, mainMediaDragging,mainMediaInteracting;
    private boolean suggestionTouch, suggestionDrag, suggestionScrolling, screenOff;
    private final Runnable suggestionScrollIdle=() -> {
        suggestionScrolling=false;updateSuggestionVisibility();
    };
    private final android.content.BroadcastReceiver screenChanges=new android.content.BroadcastReceiver() {
        @Override public void onReceive(Context context,android.content.Intent intent) {
            screenOff=android.content.Intent.ACTION_SCREEN_OFF.equals(intent.getAction());
            updateSuggestionVisibility();
        }
    };
    private int expandedWidth, expandedHeight;
    private int preferredWidth, preferredHeight;
    private Rect lastBounds;
    private android.animation.ValueAnimator geometry;
    // Screen-space visual bounds are independent of WindowManager relayouts.
    // During a morph the OS window is the bounded union of the two endpoints;
    // only the child surface moves/resizes on the rendering clock.
    private Rect visualBounds;
    private float expansion = 1;
    private boolean surfaceAnchored;
    private Runnable dragExpand;
    private int importing;
    private android.os.FileObserver appearanceChanges;
    private final android.content.ComponentCallbacks configurationChanges = new android.content.ComponentCallbacks() {
        @Override public void onConfigurationChanged(android.content.res.Configuration next) { main.post(ReceiveOverlay.this::configurationChanged); }
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
        handleScroller=new OverScroller(context);
        placement=context.getSharedPreferences("received-dock-placement",Context.MODE_PRIVATE);
        windows = context.getSystemService(WindowManager.class);
        shelf = new TemporaryShelf(context, this::shelfChanged);
        mediaSuggestions=new RecentMediaSuggestions(context,this::suggestMedia,shelf::clearSuggestions,
            shelf::suggestedPaths,shelf::removeMissingSuggestions);
        current = new java.lang.ref.WeakReference<>(this);
        main.post(this::restoreIfEnabled);
    }

    static void restoreShelf() {
        ReceiveOverlay overlay=current.get();if(overlay!=null)overlay.restoreIfEnabled();
    }
    private void restoreIfEnabled() {
        if(root!=null || !context.getSharedPreferences("received-popup-settings",Context.MODE_PRIVATE).getBoolean("enabled",true) ||
            !android.provider.Settings.canDrawOverlays(context))return;
        shelfVisible=!shelf.items.isEmpty();create(appForeground || placement.getBoolean(placementKey(availableBounds())+"collapsed",true));render();
        View appearing=root;
        appearing.post(() -> {
            if(root==appearing)appearing.animate().alpha(1).translationX(0).scaleX(1).scaleY(1).setDuration(180).start();
        });
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
        boolean entering=!appForeground;
        appForeground=true;
        mediaSuggestions.refresh();
        // A persistent shelf stays reachable while the user moves between apps.
        // Received records are still shown in the main app, not duplicated there.
        // Focus/lifecycle refreshes are not a new app entry. Keep a dock that
        // the user explicitly opened while already in GlobalSend expanded.
        if (entering && root != null) setCollapsed(true);
    }
    @Override public void background() {appForeground=false;mediaSuggestions.refresh();}

    private Map<String, ReceiveNotifications.Receipt> displayed() { return shelfVisible ? shelf.items : items; }

    private void suggestMedia(List<RecentMediaSuggestions.Media> media) {
        if(root!=null && DockCoordinator.afterExportFrom(root,() -> suggestMedia(media)))return;
        int offset=scroll==null?0:scroll.getScrollX();
        shelf.suggest(media);
        if(scroll!=null) {
            HorizontalScrollView owner=scroll;
            owner.post(() -> {if(scroll==owner)owner.scrollTo(offset,0);});
        }
    }

    private void shelfChanged() {
        mediaSuggestions.refresh();
        DockCoordinator.mediaSuggestionsChanged();
        if (root == null) return;
        if (DockCoordinator.afterExportFrom(root, this::shelfChanged)) return;
        renderKeepingScroll();
        main.removeCallbacks(countdown);
        if (shelf.removalSeconds() > 0) main.post(countdown);
    }
    static void clipboardChanged() {
        ReceiveOverlay overlay=current.get();
        if(overlay==null || overlay.root==null || !overlay.shelfVisible)return;
        int offset=overlay.scroll==null?0:overlay.scroll.getScrollX();
        if(DockCoordinator.afterExportFrom(overlay.root,ReceiveOverlay::clipboardChanged))return;
        overlay.render();
        if(overlay.scroll!=null) {
            HorizontalScrollView owner=overlay.scroll;
            owner.post(() -> {if(overlay.scroll==owner)owner.scrollTo(offset,0);});
        }
    }

    static void mainMediaActive(boolean active) {
        ReceiveOverlay overlay=current.get();if(overlay==null)return;
        overlay.mainMediaActive=active;
        overlay.shelf.suggestionInteraction("main",overlay.mainMediaDragging || active && overlay.mainMediaInteracting);
        if(active) {overlay.mediaSuggestions.start();overlay.mediaSuggestions.refresh();}
        else {
            overlay.shelf.setVisibleSuggestions("main",java.util.Collections.emptySet());
            if(overlay.root==null)overlay.mediaSuggestions.stop();
        }
    }
    static void mainMediaShowing(List<String> ids) {
        mainMediaShowing(ids,false);
    }
    static void mainMediaShowing(List<String> ids,boolean interacting) {
        ReceiveOverlay overlay=current.get();if(overlay==null)return;
        overlay.mainMediaInteracting=interacting;
        overlay.shelf.suggestionInteraction("main",overlay.mainMediaDragging || overlay.mainMediaActive && interacting);
        overlay.shelf.setVisibleSuggestions("main",overlay.mainMediaActive && !overlay.mainMediaDragging?
            new java.util.HashSet<>(ids):java.util.Collections.emptySet());
    }
    static String mediaSuggestionPath(String id) {
        ReceiveOverlay overlay=current.get();
        if(overlay==null || !overlay.shelf.isSuggested(id))return null;
        return overlay.shelf.items.get(id).localPath;
    }
    static void dismissMediaSuggestions(List<String> ids) {
        ReceiveOverlay overlay=current.get();if(overlay!=null)overlay.shelf.dismissSuggestions(new java.util.HashSet<>(ids));
    }
    static void mainMediaDrag(boolean dragging) {
        ReceiveOverlay overlay=current.get();if(overlay==null)return;
        overlay.mainMediaDragging=dragging;
        overlay.shelf.suggestionInteraction("main",dragging || overlay.mainMediaActive && overlay.mainMediaInteracting);
        if(dragging)overlay.shelf.setVisibleSuggestions("main",java.util.Collections.emptySet());
        else DockCoordinator.mediaSuggestionsChanged();
    }
    static void mediaSuggestionSnapshot(java.util.function.Consumer<List<Map<String,Object>>> completed) {
        ReceiveOverlay overlay=current.get();
        if(overlay==null) {completed.accept(List.of());return;}
        List<ReceiveNotifications.Receipt> snapshot=new ArrayList<>();
        Map<String,Long> offered=new LinkedHashMap<>();
        for(ReceiveNotifications.Receipt item:overlay.shelf.items.values())if(overlay.shelf.isSuggested(item.id))snapshot.add(item);
        for(ReceiveNotifications.Receipt item:snapshot)offered.put(item.id,overlay.shelf.suggestedAt(item.id));
        snapshot.sort(java.util.Comparator.comparingLong((ReceiveNotifications.Receipt item) -> overlay.shelf.suggestedAt(item.id)).reversed());
        thumbnails.execute(() -> {
            List<Map<String,Object>> result=new ArrayList<>();
            for(ReceiveNotifications.Receipt item:snapshot) {
                Bitmap image=overlay.thumbnail(item.localPath,180);
                if(image==null)continue;
                java.io.ByteArrayOutputStream bytes=new java.io.ByteArrayOutputStream();
                image.compress(Bitmap.CompressFormat.JPEG,85,bytes);image.recycle();
                Map<String,Object> value=new LinkedHashMap<>();
                value.put("id",item.id);value.put("path",item.localPath);value.put("name",item.fileName);value.put("suggestedAt",offered.get(item.id));value.put("thumbnail",bytes.toByteArray());result.add(value);
            }
            overlay.main.post(() -> {
                result.removeIf(value -> !overlay.shelf.isSuggested((String)value.get("id")));
                completed.accept(result);
            });
        });
    }

    private void configurationChanged() {
        if(root==null)return;
        if(DockCoordinator.afterExportFrom(root,this::configurationChanged))return;
        reflowForBounds(availableBounds());
    }

    /** Preserve edge attachment or relative free position across display changes. */
    private void reflowForBounds(Rect next) {
        if(lastBounds.equals(next)) { renderKeepingScroll(); return; }
        Rect previous=lastBounds;
        stopGeometry(); cancelPendingOpen();
        savePlacement();
        int oldX=layout.x, oldY=layout.y, oldWidth=layout.width, oldHeight=layout.height;
        if(dragExpand!=null)main.removeCallbacks(dragExpand);
        dragExpand=null;
        expandedWidth=Math.min(preferredWidth,Math.max(1,next.width()-dp(16)));
        expandedHeight=Math.min(preferredHeight,Math.max(1,next.height()-dp(16)));
        layout.width=collapsed?dp(18):expandedWidth;
        layout.height=collapsed?dp(72):expandedHeight;
        layout.x=collapsed?(edgeRight?next.right-layout.width:next.left)
            :projectPosition(oldX,oldWidth,previous.left,previous.right,layout.width,next.left,next.right);
        layout.y=projectPosition(oldY,oldHeight,previous.top,previous.bottom,layout.height,next.top,next.bottom);
        lastBounds=new Rect(next);
        restorePlacement(next,false);
        windows.updateViewLayout(root,layout);
        renderKeepingScroll(); finishGeometry(collapsed);savePlacement();
    }

    private String placementKey(Rect bounds) {return bounds.width()>bounds.height()?"landscape.":"portrait.";}
    private void restorePlacement(Rect bounds) {restorePlacement(bounds,true);}
    private void restorePlacement(Rect bounds,boolean restoreSide) {
        String key=placementKey(bounds);if(!placement.contains(key+"x"))return;
        if(restoreSide)edgeRight=placement.getBoolean(key+"right",true);
        layout.x=collapsed?(edgeRight?bounds.right-layout.width:bounds.left):
            bounds.left+Math.round(placement.getFloat(key+"x",1)*Math.max(0,bounds.width()-layout.width));
        layout.y=bounds.top+Math.round(placement.getFloat(key+"y",1)*Math.max(0,bounds.height()-layout.height));
        layout.x=clamp(layout.x,bounds.left,bounds.right-layout.width);
        layout.y=clamp(layout.y,bounds.top,bounds.bottom-layout.height);
    }
    private void savePlacement() {
        if(root==null)return;
        Rect bounds=lastBounds;String key=placementKey(bounds);float density=context.getResources().getDisplayMetrics().density;
        placement.edit().putFloat(key+"x",(layout.x-bounds.left)/(float)Math.max(1,bounds.width()-layout.width))
            .putFloat(key+"y",(layout.y-bounds.top)/(float)Math.max(1,bounds.height()-layout.height))
            .putBoolean(key+"right",edgeRight).putBoolean(key+"collapsed",collapsed)
            .putFloat("widthDp",preferredWidth/density).putFloat("heightDp",preferredHeight/density).apply();
    }

    private int projectPosition(int position,int size,int oldStart,int oldEnd,int newSize,int newStart,int newEnd) {
        int leading=position-oldStart,trailing=oldEnd-position-size;
        int result;
        if(leading<=dp(16))result=newStart+leading;
        else if(trailing<=dp(16))result=newEnd-newSize-trailing;
        else {
            float fraction=(float)leading/Math.max(1,oldEnd-oldStart-size);
            result=newStart+Math.round(fraction*Math.max(0,newEnd-newStart-newSize));
        }
        return clamp(result,newStart,newEnd-newSize);
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
            if (newItem) {shelfVisible = false;setCollapsed(false);}
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
        create(false);
    }
    private void create(boolean initiallyCollapsed) {
        appearance = ReceiveAppearance.load(context);
        rootAdded = false;
        root = new FrameLayout(context) {
            private boolean cancelTap;
            private boolean backgroundMove, backgroundMoved;
            private int sizingEdges;
            @Override protected void onWindowVisibilityChanged(int visibility) {
                super.onWindowVisibilityChanged(visibility);
                if(visibility!=View.VISIBLE)shelf.setVisibleSuggestions(java.util.Collections.emptySet());
                else post(ReceiveOverlay.this::updateSuggestionVisibility);
            }
            @Override public boolean dispatchDragEvent(DragEvent event) {
                if(event.getAction()==DragEvent.ACTION_DRAG_STARTED) {
                    suggestionTouch=false;suggestionDrag=event.getClipDescription()!=null;
                    updateSuggestionVisibility();
                } else if(event.getAction()==DragEvent.ACTION_DRAG_ENDED) {
                    suggestionDrag=false;post(ReceiveOverlay.this::updateSuggestionVisibility);
                }
                if(event.getAction()!=DragEvent.ACTION_DRAG_LOCATION)
                    DockCoordinator.traceDrag("overlay action="+event.getAction()+" forwarding="+(forwarding!=null));
                if(forwarding!=null && event.getAction()==DragEvent.ACTION_DRAG_EXITED)showSendTargets();
                if(forwarding!=null && targetScroll.getVisibility()==View.VISIBLE &&
                    event.getAction()!=DragEvent.ACTION_DRAG_STARTED && event.getAction()!=DragEvent.ACTION_DRAG_ENDED)
                    return dragOverTargets(event);
                return super.dispatchDragEvent(event);
            }
            @Override public boolean dispatchTouchEvent(MotionEvent event) {
                if(event.getActionMasked()==MotionEvent.ACTION_DOWN) {
                    suggestionTouch=true;updateSuggestionVisibility();
                } else if(event.getActionMasked()==MotionEvent.ACTION_UP || event.getActionMasked()==MotionEvent.ACTION_CANCEL) {
                    suggestionTouch=false;waitForSuggestionScroll();
                }
                if(event.getActionMasked()==MotionEvent.ACTION_DOWN) {
                    doubleTapGesture=false;
                    sizingEdges=collapsed || geometry!=null || hitsAction(surface,event)?0:
                        resizeEdges(event.getX(),event.getY(),getWidth(),getHeight());
                    backgroundMove=sizingEdges==0 && !collapsed && geometry==null && !hitsInteraction(surface,event);
                    backgroundMoved=false;
                    if(backgroundMove || sizingEdges!=0) {downX=event.getRawX();downY=event.getRawY();startX=layout.x;startY=layout.y;startWidth=layout.width;startHeight=layout.height;}
                }
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
                if (cancelTap && !backgroundMove && sizingEdges==0 && event.getActionMasked() == MotionEvent.ACTION_UP) {
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
                if(sizingEdges!=0) {
                    if(event.getActionMasked()==MotionEvent.ACTION_MOVE)resizeFromEdges(sizingEdges,Math.round(event.getRawX()-downX),Math.round(event.getRawY()-downY));
                    if(event.getActionMasked()==MotionEvent.ACTION_UP || event.getActionMasked()==MotionEvent.ACTION_CANCEL){sizingEdges=0;cancelTap=false;savePlacement();}
                    return true;
                }
                if(backgroundMove) {
                    if(event.getActionMasked()==MotionEvent.ACTION_MOVE &&
                        Math.hypot(event.getRawX()-downX,event.getRawY()-downY)>ViewConfiguration.get(context).getScaledTouchSlop()) {
                        backgroundMoved=true;Rect bounds=availableBounds();
                        layout.x=clamp(startX+Math.round(event.getRawX()-downX),bounds.left,bounds.right-layout.width);
                        layout.y=clamp(startY+Math.round(event.getRawY()-downY),bounds.top,bounds.bottom-layout.height);
                        visualBounds=new Rect(layout.x,layout.y,layout.x+layout.width,layout.y+layout.height);
                        windows.updateViewLayout(root,layout);
                    }
                    if(event.getActionMasked()==MotionEvent.ACTION_UP || event.getActionMasked()==MotionEvent.ACTION_CANCEL) {
                        backgroundMove=false;cancelTap=false;
                        if(backgroundMoved && event.getActionMasked()==MotionEvent.ACTION_UP) {
                            Rect bounds=availableBounds();
                            if(layout.x<=bounds.left+dp(16) || layout.x+layout.width>=bounds.right-dp(16))setCollapsed(true);
                            else savePlacement();
                        }
                    }
                    return true;
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
        root.setBackground(shape(0, 0));
        surface = new FrameLayout(context);
        surface.setClipToOutline(true);
        root.addView(surface);
        root.setAlpha(0); root.setTranslationX(dp(20));
        root.setScaleX(.96f); root.setScaleY(.96f);
        expanded = new LinearLayout(context);
        expanded.setOrientation(LinearLayout.HORIZONTAL);
        // The scroll viewport reaches the outer rounded surface. Its inset is
        // scrollable padding, not a second rectangular clipping boundary.
        expanded.setPadding(0, dp(4), dp(1), dp(4));
        surface.addView(expanded);
        header = new MoveHeader(context);
        header.setOrientation(LinearLayout.VERTICAL);
        header.setGravity(Gravity.CENTER);
        count = control("", "接收", () -> { shelfVisible = false; render(); });
        count.setSingleLine(true);
        countIcon=new ImageView(context);countIcon.setImageResource(R.drawable.ic_shelf_inbox);
        countGroup=countTab(count,countIcon,() -> {shelfVisible=false;render();});
        header.addView(countGroup, new LinearLayout.LayoutParams(-1, dp(28)));
        shelfTab = control("", "暂存", this::showClipboardShelf);
        shelfIcon=new ImageView(context);shelfIcon.setImageResource(R.drawable.ic_shelf_folder);
        shelfGroup=countTab(shelfTab,shelfIcon,this::showClipboardShelf);
        header.addView(shelfGroup, new LinearLayout.LayoutParams(-1, dp(28)));
        View all = icon(R.drawable.ic_drag_all, "全部拖出");
        all.setOnLongClickListener(view -> export(view, bulkDragItems()));
        header.addView(all, new LinearLayout.LayoutParams(-1, dp(28)));
        scroll = new HorizontalScrollView(context);
        scroll.setHorizontalScrollBarEnabled(false);
        scroll.setPadding(dp(4),0,0,0);
        scroll.setClipToPadding(false);
        scroll.setOnScrollChangeListener((view,x,y,oldX,oldY) -> waitForSuggestionScroll());
        row = new LinearLayout(context);
        row.setOrientation(LinearLayout.HORIZONTAL);
        scroll.addView(row, new HorizontalScrollView.LayoutParams(-2, -1));
        expanded.addView(scroll, new LinearLayout.LayoutParams(0, -1, 1));
        rail=new LinearLayout(context);rail.setOrientation(LinearLayout.VERTICAL);
        rail.addView(header,new LinearLayout.LayoutParams(-1,-1));
        expanded.addView(rail,new LinearLayout.LayoutParams(dp(38),-1));
        // Keep the native drag source attached underneath the temporary target
        // strip: rebuilding the content row would terminate a system drag.
        targetScroll=new HorizontalScrollView(context);
        targetScroll.setHorizontalScrollBarEnabled(false);
        targetScroll.setPadding(dp(4),dp(4),dp(4),dp(4));
        targetRow=new LinearLayout(context);targetRow.setOrientation(LinearLayout.HORIZONTAL);
        targetScroll.addView(targetRow,new HorizontalScrollView.LayoutParams(-2,-1));
        targetScroll.setVisibility(View.GONE);
        surface.addView(targetScroll,new FrameLayout.LayoutParams(-1,-1));
        handle = label("", 10, appearance.accent);
        handle.setGravity(Gravity.CENTER); handle.setContentDescription("展开文件暂存坞");
        handle.setOnClickListener(view -> {
            setCollapsed(false);
            withClipboardFocus(DockCoordinator::refreshClipboardSuggestion);
        });
        installEdgeMove(handle);
        handle.setVisibility(View.GONE);
        surface.addView(handle, new FrameLayout.LayoutParams(dp(18), dp(72), Gravity.CENTER_VERTICAL | Gravity.RIGHT));
        root.setOnDragListener((view, event) -> receiveDrop(event));
        layout = new WindowManager.LayoutParams(dp(232), dp(116),
            Build.VERSION.SDK_INT >= 26 ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY : WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL |
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT);
        layout.gravity = Gravity.TOP | Gravity.LEFT;
        layout.windowAnimations=0;
        // Otherwise tightening a right-edge envelope starts a second system
        // move animation after our child-surface animation has already ended.
        if(Build.VERSION.SDK_INT>=34)layout.setCanPlayMoveAnimation(false);
        layout.setTitle("GlobalSend 接收");
        Rect bounds = availableBounds();
        lastBounds=new Rect(bounds);
        preferredWidth=Math.round(placement.getFloat("widthDp",232)*context.getResources().getDisplayMetrics().density);
        preferredHeight=Math.round(placement.getFloat("heightDp",116)*context.getResources().getDisplayMetrics().density);
        layout.width=preferredWidth;layout.height=preferredHeight;
        layout.width = Math.min(layout.width, bounds.width() - dp(16));
        layout.height = Math.min(layout.height, bounds.height() - dp(16));
        layout.x = bounds.right - layout.width - dp(8);
        layout.y = bounds.bottom - layout.height - dp(12);
        expandedWidth = layout.width; expandedHeight = layout.height; collapsed = initiallyCollapsed;
        if(initiallyCollapsed) {layout.width=dp(18);layout.height=dp(72);layout.x=bounds.right-layout.width;}
        restorePlacement(bounds);
        placeControlRail();
        visualBounds = new Rect(layout.x,layout.y,layout.x+layout.width,layout.y+layout.height);
        expansion=initiallyCollapsed?0:1;surfaceAnchored=false;
        surface.setLayoutParams(new FrameLayout.LayoutParams(layout.width,layout.height));
        styleSurface();
        expanded.setLayoutParams(new FrameLayout.LayoutParams(expandedWidth, expandedHeight));
        expanded.setVisibility(initiallyCollapsed?View.GONE:View.VISIBLE);
        handle.setVisibility(initiallyCollapsed?View.VISIBLE:View.GONE);styleHandle();
        windows.addView(root, layout);
        final View owner=root;
        final boolean[] firstDraw={true};
        root.getViewTreeObserver().addOnPreDrawListener(() -> {
            if(firstDraw[0]) {
                firstDraw[0]=false;
                if(root==owner && !initiallyCollapsed && !collapsed)
                    owner.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
            }
            if(root==owner && surfaceAnchored) {
                positionSurface();
                // Wait for the union surface to be drawn before starting the
                // child animation. There is no per-frame OS move/resize race.
                if(geometry!=null && !geometry.isStarted() && root.getWidth()==layout.width && root.getHeight()==layout.height)
                    geometry.start();
            }
            if(root==owner)updateSuggestionVisibility();
            return true;
        });
        rootAdded = true;
        context.registerComponentCallbacks(configurationChanges);
        screenOff=!context.getSystemService(android.os.PowerManager.class).isInteractive();
        android.content.IntentFilter screenFilter=new android.content.IntentFilter(android.content.Intent.ACTION_SCREEN_OFF);
        screenFilter.addAction(android.content.Intent.ACTION_SCREEN_ON);
        if(Build.VERSION.SDK_INT>=33)context.registerReceiver(screenChanges,screenFilter,Context.RECEIVER_NOT_EXPORTED);
        else context.registerReceiver(screenChanges,screenFilter);
        appearanceChanges = new android.os.FileObserver(context.getFilesDir().getPath(), android.os.FileObserver.CLOSE_WRITE | android.os.FileObserver.MOVED_TO) {
            @Override public void onEvent(int event, String path) {
                if ("appearance.json".equals(path)) main.post(() -> shelfChanged());
                if ("recent-photo-suggestions.json".equals(path)) main.post(() -> mediaSuggestions.refresh());
            }
        };
        appearanceChanges.startWatching();
        mediaSuggestions.start();
    }

    private void render() {render(true);}
    private void waitForSuggestionScroll() {
        suggestionScrolling=true;
        shelf.suggestionInteraction("overlay",true);
        shelf.setVisibleSuggestions(java.util.Collections.emptySet());
        main.removeCallbacks(suggestionScrollIdle);main.postDelayed(suggestionScrollIdle,150);
    }
    private void updateSuggestionVisibility() {
        shelf.suggestionInteraction("overlay",root!=null && !screenOff && !collapsed && (suggestionTouch || suggestionDrag || suggestionScrolling || forwarding!=null || geometry!=null));
        java.util.Set<String> visible=new java.util.HashSet<>();
        if(root!=null && rootAdded && shelfVisible && !collapsed && geometry==null && !screenOff &&
                !suggestionTouch && !suggestionDrag && !suggestionScrolling && forwarding==null &&
                importing==0 && root.isShown() && root.getAlpha()>=.99f && scroll.isShown()) {
            Rect viewport=new Rect();
            if(scroll.getGlobalVisibleRect(viewport))for(int i=0;i<row.getChildCount();i++) {
                View card=row.getChildAt(i);
                if(!(card.getTag() instanceof ReceiveNotifications.Receipt) || card.getAlpha()<.99f)continue;
                ReceiveNotifications.Receipt item=(ReceiveNotifications.Receipt)card.getTag();
                if(!shelf.isSuggested(item.id))continue;
                Rect exposed=new Rect();
                // A clipped sliver at the edge is not a viewed suggestion.
                if(card.getGlobalVisibleRect(exposed) && exposed.intersect(viewport) &&
                        (long)exposed.width()*exposed.height()*2>=(long)card.getWidth()*card.getHeight())visible.add(item.id);
            }
        }
        shelf.setVisibleSuggestions(visible);
    }
    private void placeControlRail() {
        // The controls stay on the attached edge; the viewport opens inward.
        // Reorder the existing views so gestures, content and scroll survive.
        int index=edgeRight?1:0;
        if(expanded.indexOfChild(rail)!=index) {
            expanded.removeView(rail);
            expanded.addView(rail,index,new LinearLayout.LayoutParams(dp(38),-1));
        }
        expanded.setPadding(edgeRight?0:dp(1),dp(4),edgeRight?dp(1):0,dp(4));
        scroll.setPadding(edgeRight?dp(4):0,0,edgeRight?0:dp(4),0);
    }
    private void render(boolean animateChanges) {
        shelf.setVisibleSuggestions(java.util.Collections.emptySet());
        placeControlRail();
        appearance = ReceiveAppearance.load(context);
        if(geometry==null) {
            visualBounds=new Rect(layout.x,layout.y,layout.x+layout.width,layout.y+layout.height);
            surface.setLayoutParams(new FrameLayout.LayoutParams(layout.width,layout.height));
        }
        styleSurface();
        for (int i=0;i<header.getChildCount();i++) {
            View child = header.getChildAt(i);
            if (child instanceof TextView) ((TextView)child).setTextColor(appearance.accent);
            if (child instanceof ImageView) ((ImageView)child).setColorFilter(appearance.accent);
        }
        styleHandle();
        expanded.setLayoutParams(new FrameLayout.LayoutParams(expandedWidth, expandedHeight,
            Gravity.TOP | (edgeRight ? Gravity.LEFT : Gravity.RIGHT)));
        handle.setLayoutParams(new FrameLayout.LayoutParams(dp(18), dp(72),
            Gravity.CENTER_VERTICAL | (edgeRight ? Gravity.RIGHT : Gravity.LEFT)));
        Map<String,Integer> oldPositions=new LinkedHashMap<>();
        boolean animateCards=animateChanges && root.isLaidOut() && root.getAlpha()>.9f;
        for(int i=row.getChildCount()-1;i>=0;i--) {
            View previous=row.getChildAt(i);
            if(!(previous.getTag() instanceof ReceiveNotifications.Receipt))continue;
            String id=((ReceiveNotifications.Receipt)previous.getTag()).id;oldPositions.put(id,previous.getLeft());
            if(animateCards && !displayed().containsKey(id)) {
                LinearLayout owner=row;owner.getOverlay().add(previous);
                previous.animate().alpha(0).translationY(dp(10)).scaleX(.94f).scaleY(.94f).setDuration(140).start();
                main.postDelayed(() -> owner.getOverlay().remove(previous),150);
            }
        }
        row.removeAllViews();
        List<FrameLayout> cards=new ArrayList<>();
        updateLabels();
        int side = Math.max(1, expandedHeight - dp(8));
        if (displayed().isEmpty() && !shelfVisible) {
            TextView empty = label(shelfVisible ? "拖入文件、图片或文字" : "暂无接收内容", 13, appearance.muted);
            empty.setTag("empty-receive");
            empty.setGravity(Gravity.CENTER);
            row.addView(empty, new LinearLayout.LayoutParams(expandedWidth - dp(43), side));
        }
        List<ReceiveNotifications.Receipt> ordered=new ArrayList<>(),suggested=new ArrayList<>();
        for(ReceiveNotifications.Receipt receipt:displayed().values()) {
            if(shelfVisible && shelf.isSuggested(receipt.id))suggested.add(receipt);
            else ordered.add(receipt);
        }
        suggested.sort(java.util.Comparator.comparingLong((ReceiveNotifications.Receipt item) -> shelf.suggestedAt(item.id)).reversed());
        Map<String,Object> clipboard=shelfVisible?DockCoordinator.clipboardSuggestion():java.util.Collections.emptyMap();
        long clipboardAt=((Number)clipboard.getOrDefault("suggestedAt",0L)).longValue();
        boolean clipboardPending=!"empty".equals(clipboard.getOrDefault("kind","empty"));
        boolean hasContent=!ordered.isEmpty(),tailAdded=false,clipboardAdded=false;
        ordered.addAll(suggested);
        for (ReceiveNotifications.Receipt receipt : ordered) {
            if(shelfVisible && !tailAdded && shelf.isSuggested(receipt.id)) {
                appendListTail(side,hasContent);tailAdded=true;
            }
            if(shelfVisible && shelf.isSuggested(receipt.id) && clipboardPending && !clipboardAdded && clipboardAt>=shelf.suggestedAt(receipt.id)) {
                appendClipboardSuggestion(side,clipboard);clipboardAdded=true;
            }
            FrameLayout card = new FrameLayout(context);
            card.setTag(receipt);
            card.setClipToOutline(true);
            boolean pending = shelfVisible && shelf.pendingRemoval(receipt.id);
            View content;
            boolean picture=receipt.text == null && !receipt.localPath.isEmpty() &&
                receipt.fileName.toLowerCase(java.util.Locale.ROOT).matches(".*\\.(png|jpe?g|webp|gif|bmp|heic|heif|mp4|mov|m4v|webm|mkv|3gp)$");
            if (picture) {
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
                text.setPadding(dp(8),dp(8),dp(8),dp(28));
                text.setMaxLines(3);
                text.setEllipsize(android.text.TextUtils.TruncateAt.END);
                if(receipt.text==null && !receipt.localPath.isEmpty() && !receipt.fileName.contains(".")) {
                    FrameLayout preview=new FrameLayout(context);
                    preview.addView(text,new FrameLayout.LayoutParams(-1,-1));
                    ImageView image=new ImageView(context);image.setScaleType(ImageView.ScaleType.CENTER_CROP);
                    image.setVisibility(View.GONE);preview.addView(image,new FrameLayout.LayoutParams(-1,-1));
                    thumbnails.execute(() -> {
                        Bitmap bitmap=thumbnail(receipt.localPath,dp(160));
                        main.post(() -> {if(image.getParent()!=null && bitmap!=null) {
                            image.setImageBitmap(bitmap);image.setVisibility(View.VISIBLE);text.setVisibility(View.GONE);
                        }});
                    });
                    content=preview;
                } else content = text;
            }
            card.addView(content,new FrameLayout.LayoutParams(-1,-1));
            View tint=new View(context);tint.setTag("pending-tint");tint.setBackgroundColor(0x33d84c53);
            tint.setVisibility(pending ? View.VISIBLE : View.GONE);
            card.addView(tint,new FrameLayout.LayoutParams(-1,-1));
            TextView remove = control("×", "移除", () -> remove(receipt));
            remove.setTag("remove-item");
            remove.setTextSize(24);
            // A larger transparent target, without another rounded tile on top.
            remove.setShadowLayer(dp(1),0,0,glass(appearance.surface,0xb3));
            FrameLayout.LayoutParams removeSize=new FrameLayout.LayoutParams(dp(36),dp(36),Gravity.TOP|Gravity.RIGHT);
            removeSize.topMargin=dp(2);removeSize.rightMargin=dp(2);
            card.addView(remove,removeSize);
            View deleting = icon(android.R.drawable.ic_menu_delete,"3秒后移除，轻点取消");
            deleting.setTag("pending-removal"); deleting.setVisibility(pending ? View.VISIBLE : View.GONE);
            ((ImageView)deleting).setColorFilter(0xffd84c53);
            FrameLayout.LayoutParams deletingSize=new FrameLayout.LayoutParams(dp(24),dp(24),Gravity.BOTTOM|Gravity.LEFT);
            deletingSize.leftMargin=dp(4);deletingSize.bottomMargin=dp(4);card.addView(deleting,deletingSize);
            if (receipt.text != null) {
                FrameLayout.LayoutParams copySize=new FrameLayout.LayoutParams(dp(40),dp(24),Gravity.BOTTOM|Gravity.RIGHT);
                copySize.rightMargin=dp(4);copySize.bottomMargin=dp(4);
                card.addView(control("复制", "复制", () -> copy(receipt)),copySize);
            }
            styleCard(card,pending);
            card.setOnClickListener(view -> {
                if(shelfVisible && shelf.isSuggested(receipt.id))
                    shelf.add(List.of(receipt.localPath),List.of(),Map.of(receipt.localPath,receipt.fileName));
                else queueOpen(receipt);
            });
            card.setOnLongClickListener(view -> {
                return export(view, java.util.Collections.singletonList(receipt));
            });
            LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(side, side);
            size.rightMargin = dp(3);
            if(animateCards && !oldPositions.containsKey(receipt.id)) {card.setAlpha(0);card.setTranslationY(-dp(14));}
            row.addView(card, size);
            cards.add(card);
        }
        if(!tailAdded)appendListTail(side,hasContent);
        if(shelfVisible && !clipboardAdded)appendClipboardSuggestion(side,clipboard);
        scroll.scrollTo(0, 0);
        if(animateCards) {
            LinearLayout owner=row;
            owner.getViewTreeObserver().addOnPreDrawListener(new ViewTreeObserver.OnPreDrawListener() {
                @Override public boolean onPreDraw() {
                    owner.getViewTreeObserver().removeOnPreDrawListener(this);
                    if(row!=owner)return true;
                    for(FrameLayout card:cards)if(card.getParent()==owner) {
                        String id=((ReceiveNotifications.Receipt)card.getTag()).id;
                        Integer old=oldPositions.get(id);
                        if(old!=null)card.setTranslationX(old-card.getLeft());
                        card.animate().alpha(1).translationX(0).translationY(0).setDuration(180)
                            .setInterpolator(new android.view.animation.DecelerateInterpolator()).start();
                    }
                    return true;
                }
            });
        }
    }

    private void showClipboardShelf() {
        shelfVisible=true;render();withClipboardFocus(DockCoordinator::refreshClipboardSuggestion);
    }
    private void appendClipboardSuggestion(int side,Map<String,Object> suggestion) {
        String kind=(String)suggestion.getOrDefault("kind","empty");
        if(kind.equals("empty"))return;
        String revision=(String)suggestion.get("revision");
        FrameLayout card=new FrameLayout(context);card.setTag("clipboard-suggestion");
        card.setContentDescription("剪贴板建议");styleCard(card,false);
        card.setBackground(shape(glass(listSoft(),0x59),12));
        GradientDrawable suggestionBorder=shape(0,12);suggestionBorder.setStroke(dp(1),listAccent(),dp(4),dp(3));card.setForeground(suggestionBorder);
        LinearLayout body=new LinearLayout(context);body.setGravity(Gravity.CENTER);body.setOrientation(LinearLayout.VERTICAL);
        View clipboardIcon=icon(R.drawable.ic_shelf_clipboard,"剪贴板");clipboardIcon.setPadding(0,0,0,0);
        body.addView(clipboardIcon,new LinearLayout.LayoutParams(dp(28),dp(28)));
        String type=kind.equals("image")?"图片":kind.equals("files")?"文件":"文本";
        TextView label=label("剪贴板 · "+type,12,listAccent());label.setGravity(Gravity.CENTER);
        body.addView(label,new LinearLayout.LayoutParams(-1,dp(28)));
        TextView confirm=label("点按添加",11,appearance.muted);confirm.setGravity(Gravity.CENTER);
        body.addView(confirm,new LinearLayout.LayoutParams(-1,dp(16)));
        card.addView(body,new FrameLayout.LayoutParams(-1,-1));
        TextView ignore=label("×",24,listAccent());ignore.setGravity(Gravity.CENTER);ignore.setContentDescription("忽略剪贴板建议");
        ignore.setOnClickListener(v -> DockCoordinator.dismissClipboardSuggestion(revision));
        card.addView(ignore,new FrameLayout.LayoutParams(dp(36),dp(36),Gravity.TOP|Gravity.RIGHT));
        card.setOnClickListener(v -> withClipboardFocus(() -> {
            importing++;updateLabels();
            boolean accepted=DockCoordinator.importClipboardToShelf(content -> {
                importing--;shelf.add((List<String>)content.get("paths"),(List<String>)content.get("texts"),
                    (Map<String,String>)content.getOrDefault("directoryNames",java.util.Collections.emptyMap()));
                if(content.containsKey("error"))android.widget.Toast.makeText(context,"部分剪贴板内容无法读取",android.widget.Toast.LENGTH_SHORT).show();
                else DockCoordinator.dismissClipboardSuggestion(revision);
            });
            if(!accepted){importing--;updateLabels();android.widget.Toast.makeText(context,"剪贴板为空",android.widget.Toast.LENGTH_SHORT).show();}
        }));
        LinearLayout.LayoutParams size=new LinearLayout.LayoutParams(side,side);size.rightMargin=dp(3);row.addView(card,size);
    }

    /** A deliberate paste tap may focus this bounded window; never a drag hover. */
    private void withClipboardFocus(Runnable read) {
        final View owner=root;
        if(owner==null)return;
        // The foreground app already has clipboard access. Taking focus here
        // makes Flutter inactive/resumed and used to immediately fold the dock.
        if(appForeground){read.run();return;}
        final int focusFlags=WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE|WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM;
        final int prior=layout.flags&focusFlags;
        class FocusedRead implements ViewTreeObserver.OnWindowFocusChangeListener,Runnable {
            boolean finished;
            public void onWindowFocusChanged(boolean focused){if(focused)run();}
            public void run(){
                if(finished)return;finished=true;main.removeCallbacks(this);
                if(owner.getViewTreeObserver().isAlive())owner.getViewTreeObserver().removeOnWindowFocusChangeListener(this);
                if(root!=owner)return;
                try {
                    if(owner.hasWindowFocus())read.run();
                    else android.widget.Toast.makeText(context,"请在应用内读取剪贴板",android.widget.Toast.LENGTH_SHORT).show();
                } finally {
                    if(root==owner){layout.flags=(layout.flags&~focusFlags)|prior;windows.updateViewLayout(owner,layout);}
                }
            }
        }
        FocusedRead request=new FocusedRead();
        owner.getViewTreeObserver().addOnWindowFocusChangeListener(request);
        layout.flags=(layout.flags&~WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE)|WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM;
        owner.setFocusableInTouchMode(true);windows.updateViewLayout(owner,layout);owner.requestFocus();
        main.postDelayed(request,500);
        if(owner.hasWindowFocus())request.run();
    }

    private void appendListTail(int side,boolean hasContent) {
        if (hasContent) {
            LinearLayout clear = new LinearLayout(context);
            clear.setGravity(Gravity.CENTER); clear.setOrientation(LinearLayout.VERTICAL);
            clear.setBackground(shape(glass(listSoft(),0xb3),12)); clear.setContentDescription("清空当前列表");
            TextView clearIcon=label("×",30,listAccent());
            clearIcon.setGravity(Gravity.CENTER);
            clear.addView(clearIcon,new LinearLayout.LayoutParams(dp(40),dp(40)));
            TextView clearLabel=label("清空",12,appearance.muted);clearLabel.setGravity(Gravity.CENTER);
            clear.addView(clearLabel);
            clear.setOnClickListener(view -> clearDisplayed());
            LinearLayout.LayoutParams clearSize=new LinearLayout.LayoutParams(side,side);clearSize.rightMargin=dp(3);
            row.addView(clear,clearSize);
        }
        if(shelfVisible || hasContent) {
            View openSpace=new View(context);openSpace.setTag("open-app-space");
            openSpace.setContentDescription("双击打开 GlobalSend");
            // With no staged content the initial viewport stays completely blank;
            // suggestions are reached by swiping, never replacing the app-opening area.
            int width=shelfVisible && !hasContent?Math.max(side,expandedWidth-dp(43)):side;
            row.addView(openSpace,new LinearLayout.LayoutParams(width,side));
        }
    }

    private int pendingColor() {
        return android.graphics.Color.luminance(appearance.surface) < .3f ? 0xff542b32 : 0xffffe4e6;
    }
    private int listAccent() {return shelfVisible?appearance.accent:appearance.receivedAccent;}
    private int listSoft() {return shelfVisible?appearance.stagedSoft:appearance.receivedSoft;}
    private void styleCard(FrameLayout card,boolean pending) {
        card.setBackground(shape(pending?pendingColor():glass(listSoft(),0xb3),12));
        GradientDrawable border=shape(0,12);border.setStroke(dp(1),pending?0xffd84c53:listAccent());
        card.setForeground(border);
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
        if(view.getVisibility()!=View.VISIBLE || !hits(view,event))return false;
        if("clipboard-suggestion".equals(view.getTag()))return true;
        if(((view instanceof TextView || view instanceof ImageView) && view.isClickable()) ||
            view==countGroup || view==shelfGroup ||
            "清空当前列表".contentEquals(view.getContentDescription()==null?"":view.getContentDescription()))return true;
        if(view instanceof android.view.ViewGroup) {
            android.view.ViewGroup group=(android.view.ViewGroup)view;
            for(int i=0;i<group.getChildCount();i++)if(hitsAction(group.getChildAt(i),event))return true;
        }
        return false;
    }
    private boolean hitsInteraction(View view,MotionEvent event) {
        if(view.getVisibility()!=View.VISIBLE || !hits(view,event))return false;
        // Unconfirmed clipboard cards are not in displayed(), but the opening
        // space still belongs to the overflowing list, not to window movement.
        if(view==scroll && (!displayed().isEmpty() || scroll.canScrollHorizontally(-1) || scroll.canScrollHorizontally(1)) ||
            view.isClickable() || view.isLongClickable())return true;
        if(view instanceof android.view.ViewGroup) {
            android.view.ViewGroup group=(android.view.ViewGroup)view;
            for(int i=0;i<group.getChildCount();i++)if(hitsInteraction(group.getChildAt(i),event))return true;
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
            styleCard((FrameLayout)card,pending);
            card.findViewWithTag("pending-removal").setVisibility(pending ? View.VISIBLE : View.GONE);
            card.findViewWithTag("pending-tint").setVisibility(pending ? View.VISIBLE : View.GONE);
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
        countGroup.setContentDescription(count.getContentDescription());
        shelfGroup.setContentDescription(shelfTab.getContentDescription());
        count.setTextColor(appearance.receivedAccent);countIcon.setColorFilter(appearance.receivedAccent);
        shelfTab.setTextColor(appearance.accent);shelfIcon.setColorFilter(appearance.accent);
        countGroup.setAlpha(shelfVisible?.65f:1);shelfGroup.setAlpha(shelfVisible?1:.65f);
        count.setTypeface(null, shelfVisible ? 0 : 1); shelfTab.setTypeface(null, shelfVisible ? 1 : 0);
        handle.setText("");
        handle.setContentDescription("展开文件暂存坞，接收 " + items.size() + " 项，暂存 " + shelf.items.size() + " 项");
        if (remaining > 0) shelfTab.setContentDescription("暂存 " + shelf.items.size() + " 项，" + remaining + " 秒后移除，轻点取消");
        else if (importing > 0) shelfTab.setContentDescription("暂存 " + shelf.items.size() + " 项，正在导入");
        shelfGroup.setContentDescription(shelfTab.getContentDescription());
    }

    List<ReceiveNotifications.Receipt> bulkDragItems() {
        List<ReceiveNotifications.Receipt> selection = new ArrayList<>();
        for (ReceiveNotifications.Receipt item : displayed().values())
            if (!shelfVisible || !shelf.isSuggested(item.id)) selection.add(item);
        return selection;
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
        long started=android.os.SystemClock.uptimeMillis();
        final ForwardDrag drag=new ForwardDrag(paths,texts,staged);
        forwarding=drag;
        updateSuggestionVisibility();
        try {
            boolean began=DockCoordinator.startDrag(source, paths, texts, (paths.size() + texts.size()) + " 项", accepted -> {
                finishForwarding(drag);
                if(drag.sentToDevice)return; // The transfer callback owns this batch's removal grace period.
                boolean[] warned={false};
                shelf.exported(staged, accepted, item -> {
                    // Directory document drags retain their original system
                    // result contract; ordinary exported files are observable.
                    boolean consumed=item.text!=null || !DockShareProvider.canObserveAccess(item.localPath) || DockShareProvider.wasAccessedSince(item.localPath,started);
                    if(!consumed && !warned[0]) {warned[0]=true;android.widget.Toast.makeText(context,"目标未读取，已保留暂存项",android.widget.Toast.LENGTH_SHORT).show();}
                    return consumed;
                });
            },true);
            if(!began)finishForwarding(drag);
            return began;
        } catch (Exception unavailable) {
            finishForwarding(drag);
            android.util.Log.w("GlobalSend", "Cannot export temporary shelf drag", unavailable);
            android.widget.Toast.makeText(context, "无法拖出，请重试", android.widget.Toast.LENGTH_SHORT).show(); return false;
        }
    }

    static void refreshSendTargets() {
        ReceiveOverlay overlay=current.get();
        if(overlay!=null && overlay.forwarding!=null && overlay.targetScroll!=null &&
            overlay.targetScroll.getVisibility()==View.VISIBLE)overlay.renderSendTargets();
    }
    private void showSendTargets() {
        DockCoordinator.traceDrag("show targets requested forwarding="+(forwarding!=null));
        if(forwarding==null || root==null || targetScroll.getVisibility()==View.VISIBLE)return;
        renderSendTargets();
        styleSurface();
        expanded.setAlpha(0); // No detach, visibility change, or replacement of the active source.
        targetScroll.setVisibility(View.VISIBLE);targetScroll.setAlpha(0);
        targetScroll.animate().alpha(1).setDuration(120).start();
    }
    private void renderSendTargets() {
        targetRow.removeAllViews();hoveredTarget=null;
        int side=Math.max(1,expandedHeight-dp(8));
        for(Map<String,String> device:DockCoordinator.sendTargets()) {
            LinearLayout card=new LinearLayout(context);card.setOrientation(LinearLayout.VERTICAL);card.setGravity(Gravity.CENTER);
            card.setTag(device.get("deviceId"));card.setContentDescription("发送到 "+device.get("name"));
            card.setBackground(shape(glass(appearance.soft,0xb3),12));
            ImageView image=new ImageView(context);
            String platform=device.get("platform");
            image.setImageResource("windows".equals(platform)?R.drawable.ic_device_desktop:
                "web".equals(platform)?R.drawable.ic_device_web:R.drawable.ic_device_mobile);
            image.setColorFilter(appearance.accent);card.addView(image,new LinearLayout.LayoutParams(dp(26),dp(26)));
            TextView name=label(device.getOrDefault("name","设备"),12,appearance.ink);
            name.setGravity(Gravity.CENTER);name.setMaxLines(2);name.setEllipsize(android.text.TextUtils.TruncateAt.END);
            LinearLayout.LayoutParams nameSize=new LinearLayout.LayoutParams(-1,-2);nameSize.topMargin=dp(6);
            card.setPadding(dp(6),dp(6),dp(6),dp(6));card.addView(name,nameSize);
            LinearLayout.LayoutParams size=new LinearLayout.LayoutParams(side,side);size.rightMargin=dp(3);
            targetRow.addView(card,size);
        }
        if(targetRow.getChildCount()==0) {
            TextView empty=label("暂无可发送设备",13,appearance.muted);empty.setGravity(Gravity.CENTER);
            targetRow.addView(empty,new LinearLayout.LayoutParams(expandedWidth-dp(8),side));
        }
    }
    private void highlightTarget(float x,float y) {
        View next=null;
        Rect bounds=new Rect();
        for(int i=0;i<targetRow.getChildCount();i++) {
            View card=targetRow.getChildAt(i);
            if(!(card.getTag() instanceof String))continue;
            card.getDrawingRect(bounds);root.offsetDescendantRectToMyCoords(card,bounds);
            if(bounds.contains((int)x,(int)y)){next=card;break;}
        }
        if(next==hoveredTarget)return;
        if(hoveredTarget!=null)hoveredTarget.setBackground(shape(glass(appearance.soft,0xb3),12));
        hoveredTarget=next;
        if(next!=null) {
            GradientDrawable background=shape(glass(appearance.soft,0xe6),12);
            background.setStroke(dp(2),appearance.accent);next.setBackground(background);
        }
    }
    private boolean dragOverTargets(DragEvent event) {
        int action=event.getAction();
        if(action==DragEvent.ACTION_DRAG_EXITED) {dragInside=false;stopTargetScroll();highlightTarget(-1,-1);return true;}
        if(action==DragEvent.ACTION_DRAG_ENTERED || action==DragEvent.ACTION_DRAG_LOCATION) {
            if(action==DragEvent.ACTION_DRAG_ENTERED)feedbackDragEntry();
            targetPointerX=event.getX();targetPointerY=event.getY();highlightTarget(targetPointerX,targetPointerY);
            int zone=dp(36);
            int direction=targetPointerX<zone?-1:targetPointerX>root.getWidth()-zone?1:0;
            targetEdgeDepth=Math.max(0,Math.min(1,direction<0?(zone-targetPointerX)/zone:(targetPointerX-root.getWidth()+zone)/zone));
            if(direction==0)stopTargetScroll();
            else {
                if(targetScrollDirection==0) {
                    targetScrollOffset=targetScroll.getScrollX();targetScrollFrameNanos=0;
                    Choreographer.getInstance().postFrameCallback(targetAutoScroll);
                }
                targetScrollDirection=direction;
            }
            return true;
        }
        if(action==DragEvent.ACTION_DROP) {
            stopTargetScroll();highlightTarget(event.getX(),event.getY());
            if(hoveredTarget==null)return false;
            ForwardDrag drag=forwarding;
            drag.sentToDevice=true;
            boolean accepted=DockCoordinator.sendToDevice(event,drag.serverKey,(String)hoveredTarget.getTag(),drag.paths,drag.texts,success -> {
                if(success)shelf.exported(drag.staged,true);
                android.widget.Toast.makeText(context,success?"已开始发送":"发送失败，内容已保留",android.widget.Toast.LENGTH_SHORT).show();
            });
            if(!accepted) {
                drag.sentToDevice=false;
                android.widget.Toast.makeText(context,"设备已不可用，内容已保留",android.widget.Toast.LENGTH_SHORT).show();
            }
            return accepted;
        }
        return true;
    }
    private void stopTargetScroll() {
        targetScrollDirection=0;targetScrollVelocity=0;targetScrollFrameNanos=0;
        Choreographer.getInstance().removeFrameCallback(targetAutoScroll);
    }
    private void finishForwarding(ForwardDrag drag) {
        DockCoordinator.traceDrag("finish forwarding current="+(forwarding==drag));
        if(forwarding!=drag)return;
        stopTargetScroll();forwarding=null;hoveredTarget=null;
        if(targetScroll!=null) {targetScroll.animate().cancel();targetScroll.setVisibility(View.GONE);}
        if(expanded!=null)expanded.setAlpha(1);
        updateSuggestionVisibility();
    }

    private void feedbackDragEntry() {
        if(!dragInside && root!=null)root.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
        dragInside=true;
    }

    @SuppressWarnings("unchecked")
    private boolean receiveDrop(DragEvent event) {
        switch (event.getAction()) {
            case DragEvent.ACTION_DRAG_STARTED:
                dragInside=false;
                cancelPendingOpen();
                if (shelf.cancelRemoval()) { main.removeCallbacks(countdown); shelfChanged(); }
                return event.getClipDescription() != null;
            case DragEvent.ACTION_DRAG_ENTERED:
                feedbackDragEntry();
                if (collapsed) {
                    dragExpand = () -> { dragExpand = null; setCollapsed(false); };
                    main.postDelayed(dragExpand, 250);
                }
                surface.setBackground(shape(glass(appearance.soft,0x99), 18)); return true;
            case DragEvent.ACTION_DRAG_EXITED:
                dragInside=false;
                // Since Android N, enter/exit is delivered to the innermost
                // interested View, not through dispatchDragEvent on every parent.
                // The dock root owns this gesture, including its completion.
                if(forwarding!=null)showSendTargets();
                stopTargetScroll();
                if (dragExpand != null) main.removeCallbacks(dragExpand);
                dragExpand = null;
                if (root != null) styleSurface();
                return true;
            case DragEvent.ACTION_DRAG_ENDED:
                dragInside=false;
                if(root!=null)DockCoordinator.finishExportFrom(root,event);
                if (dragExpand != null) main.removeCallbacks(dragExpand);
                dragExpand = null;
                if (root != null) styleSurface();
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
        android.widget.Toast.makeText(context,"已复制",android.widget.Toast.LENGTH_SHORT).show();
    }
    private void open(ReceiveNotifications.Receipt receipt) {
        if (!receipt.id.startsWith("shelf:")) { actions.open(receipt.id); return; }
        if (receipt.text != null) { copy(receipt); return; }
        try {
            android.net.Uri uri = receipt.localPath.startsWith("content://") ? android.net.Uri.parse(receipt.localPath) :
                DockShareProvider.register(context, new java.io.File(receipt.localPath), receipt.fileName);
            AndroidFileOpener.open(context, uri);
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
                    stopGeometry();
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
                    if(geometry==null)savePlacement();
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
            visualBounds=new Rect(layout.x,layout.y,layout.x+layout.width,layout.y+layout.height);
            windows.updateViewLayout(root, layout);
        }
    }

    private int resizeEdges(float x,float y,int width,int height) {
        int edge=dp(12),corner=dp(20);
        boolean nearSide=x<corner || x>width-corner;
        boolean nearEnd=y<corner || y>height-corner;
        int horizontal=nearEnd?corner:edge,vertical=nearSide?corner:edge;
        return (x<horizontal?1:0)|(x>width-horizontal?2:0)|
            (y<vertical?4:0)|(y>height-vertical?8:0);
    }
    private void resizeFromEdges(int edges,int dx,int dy) {
        Rect bounds=availableBounds();int left=startX,right=startX+startWidth,top=startY,bottom=startY+startHeight;
        int minW=dp(152),maxW=Math.min(dp(400),bounds.width()-dp(16));
        int minH=dp(92),maxH=Math.min(dp(260),bounds.height()-dp(16));
        if((edges&1)!=0)left=clamp(startX+dx,Math.max(bounds.left,right-maxW),right-minW);
        if((edges&2)!=0)right=clamp(startX+startWidth+dx,left+minW,Math.min(bounds.right,left+maxW));
        if((edges&4)!=0)top=clamp(startY+dy,Math.max(bounds.top,bottom-maxH),bottom-minH);
        if((edges&8)!=0)bottom=clamp(startY+startHeight+dy,top+minH,Math.min(bounds.bottom,top+maxH));
        layout.x=left;layout.y=top;layout.width=right-left;layout.height=bottom-top;
        preferredWidth=expandedWidth=layout.width;preferredHeight=expandedHeight=layout.height;
        visualBounds=new Rect(left,top,right,bottom);surfaceAnchored=true;
        windows.updateViewLayout(root,layout);
        // Resize the existing view tree. Rebuilding it here clears every image
        // and queues another decode for each pointer movement.
        surface.setLayoutParams(new FrameLayout.LayoutParams(layout.width,layout.height));
        expanded.setLayoutParams(new FrameLayout.LayoutParams(expandedWidth,expandedHeight,
            Gravity.TOP | (edgeRight?Gravity.LEFT:Gravity.RIGHT)));
        int side=Math.max(1,expandedHeight-dp(8));
        boolean hasContent=displayed().values().stream().anyMatch(item -> !shelfVisible || !shelf.isSuggested(item.id));
        for(int i=0;i<row.getChildCount();i++) {
            View child=row.getChildAt(i);
            LinearLayout.LayoutParams size=(LinearLayout.LayoutParams)child.getLayoutParams();
            int width="empty-receive".equals(child.getTag())?expandedWidth-dp(43):
                "open-app-space".equals(child.getTag()) && shelfVisible && !hasContent?
                    Math.max(side,expandedWidth-dp(43)):side;
            if(size.width!=width || size.height!=side) {
                size.width=width;size.height=side;child.setLayoutParams(size);
            }
        }
        styleSurface();positionSurface();root.requestLayout();root.invalidate();
    }
    private void installEdgeMove(View view) {
        final boolean[] pulledOpen={false};
        view.setOnTouchListener((handle, event) -> {
            if (event.getActionMasked() == MotionEvent.ACTION_DOWN) {
                pulledOpen[0]=false;
                stopGeometry();
                releaseHandleVelocity();handleVelocity=VelocityTracker.obtain();
                trackHandleVelocity(event);
                downX = event.getRawX(); downY = event.getRawY(); startY = layout.y;
                return true;
            }
            if (event.getActionMasked() == MotionEvent.ACTION_MOVE) {
                trackHandleVelocity(event);
                if(pulledOpen[0])return true;
                int dx = Math.round(event.getRawX() - downX), dy = Math.round(event.getRawY() - downY);
                if ((edgeRight ? -dx : dx) > dp(28)) { pulledOpen[0]=true;releaseHandleVelocity();setCollapsed(false);return true; }
                Rect bounds = availableBounds();
                layout.y = clamp(startY + dy, bounds.top, bounds.bottom - layout.height);
                visualBounds=new Rect(layout.x,layout.y,layout.x+layout.width,layout.y+layout.height);
                windows.updateViewLayout(root, layout); return true;
            }
            if(event.getActionMasked()==MotionEvent.ACTION_UP && pulledOpen[0]) {pulledOpen[0]=false;releaseHandleVelocity();return true;}
            if(event.getActionMasked()==MotionEvent.ACTION_CANCEL) {pulledOpen[0]=false;releaseHandleVelocity();savePlacement();return true;}
            int velocity=0;
            if(event.getActionMasked()==MotionEvent.ACTION_UP && handleVelocity!=null) {
                trackHandleVelocity(event);
                handleVelocity.computeCurrentVelocity(1000,ViewConfiguration.get(context).getScaledMaximumFlingVelocity());
                velocity=Math.round(handleVelocity.getYVelocity());releaseHandleVelocity();
            }
            if (event.getActionMasked() == MotionEvent.ACTION_UP &&
                    Math.abs(event.getRawY() - downY) < dp(6) && Math.abs(event.getRawX() - downX) < dp(6)) handle.performClick();
            else if (event.getActionMasked() == MotionEvent.ACTION_UP) {
                setCollapsed(true);flingHandle(velocity);
            }
            if(event.getActionMasked()==MotionEvent.ACTION_UP && geometry==null)savePlacement();
            return true;
        });
    }

    private void trackHandleVelocity(MotionEvent event) {
        if(handleVelocity==null)return;
        // The handle's local coordinates move with its OS window. Measure
        // screen-space motion so following the finger does not cancel velocity.
        MotionEvent screen=MotionEvent.obtain(event);
        screen.offsetLocation(event.getRawX()-event.getX(),event.getRawY()-event.getY());
        handleVelocity.addMovement(screen);screen.recycle();
    }
    private void releaseHandleVelocity() {
        if(handleVelocity!=null){handleVelocity.recycle();handleVelocity=null;}
    }
    private void stopHandleFling() {
        handleScroller.forceFinished(true);
        if(root!=null)root.removeCallbacks(handleFling);
    }
    private void flingHandle(int velocity) {
        if(root==null || !collapsed || Math.abs(velocity)<ViewConfiguration.get(context).getScaledMinimumFlingVelocity())return;
        Rect bounds=availableBounds();
        handleScroller.fling(layout.x,layout.y,0,velocity,layout.x,layout.x,bounds.top,bounds.bottom-layout.height);
        root.postOnAnimation(handleFling);
    }

    void setCollapsed(boolean value) {
        if (root == null || collapsed == value && geometry != null) return;
        if (DockCoordinator.afterExportFrom(root, () -> setCollapsed(value))) return;
        stopHandleFling();
        if(collapsed && !value)root.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
        if (collapsed == value && geometry == null && layout.width == (value ? dp(18) : expandedWidth)
                && layout.height == (value ? dp(72) : expandedHeight)) {
            finishGeometry(value);savePlacement(); return;
        }
        // Reverse from the currently drawn rectangle, not the OS envelope or
        // the previous target. Cancelled completions cannot win a later morph.
        Rect initial=geometry==null?new Rect(layout.x,layout.y,layout.x+layout.width,layout.y+layout.height):new Rect(visualBounds);
        cancelGeometry();
        Rect bounds = availableBounds();
        if (value && !collapsed) {
            edgeRight = initial.centerX() >= bounds.centerX();
        }
        placeControlRail();
        collapsed = value;
        shelf.setVisibleSuggestions(java.util.Collections.emptySet());
        styleHandle();
        int width = value ? dp(18) : expandedWidth, height = value ? dp(72) : expandedHeight;
        int x = edgeRight ? bounds.right - width : bounds.left;
        int y = clamp(initial.top, bounds.top, bounds.bottom - height);
        Rect target=new Rect(x,y,x+width,y+height);
        if (initial.equals(target)) {
            visualBounds=target;commitVisualWindow();
            finishGeometry(value);savePlacement(); return;
        }
        expanded.setLayoutParams(new FrameLayout.LayoutParams(expandedWidth, expandedHeight,
            Gravity.TOP | (edgeRight ? Gravity.LEFT : Gravity.RIGHT)));
        handle.setLayoutParams(new FrameLayout.LayoutParams(dp(18), dp(72),
            Gravity.CENTER_VERTICAL | (edgeRight ? Gravity.RIGHT : Gravity.LEFT)));
        float initialExpansion=expansion;
        expanded.setVisibility(View.VISIBLE); handle.setVisibility(View.VISIBLE);
        handle.setEnabled(false); handle.setClickable(false);
        root.animate().cancel();root.setAlpha(1);root.setTranslationX(0);root.setScaleX(1);root.setScaleY(1);
        Rect envelope=new Rect(initial);envelope.union(target);
        layout.x=envelope.left;layout.y=envelope.top;layout.width=envelope.width();layout.height=envelope.height();
        visualBounds=initial;surfaceAnchored=true;
        View owner = root;
        android.animation.ValueAnimator moving = android.animation.ValueAnimator.ofFloat(0, 1);
        geometry = moving;
        moving.setDuration(240); moving.setInterpolator(new android.view.animation.DecelerateInterpolator(1.5f));
        moving.addUpdateListener(animation -> {
            if (root != owner || geometry != moving) return;
            float t = (Float)animation.getAnimatedValue();
            visualBounds=new Rect(Math.round(initial.left+(target.left-initial.left)*t),
                Math.round(initial.top+(target.top-initial.top)*t),
                Math.round(initial.right+(target.right-initial.right)*t),
                Math.round(initial.bottom+(target.bottom-initial.bottom)*t));
            expansion=initialExpansion+((value?0:1)-initialExpansion)*t;
            surface.setLayoutParams(new FrameLayout.LayoutParams(visualBounds.width(),visualBounds.height()));
            expanded.setAlpha(expansion);handle.setAlpha(1-expansion);
            styleSurface();positionSurface();
        });
        moving.addListener(new android.animation.AnimatorListenerAdapter() {
            @Override public void onAnimationEnd(android.animation.Animator animation) {
                if (root != owner || geometry != moving) return;
                geometry = null; visualBounds=target;commitVisualWindow();finishGeometry(value);savePlacement();
            }
        });
        windows.updateViewLayout(root,layout);
        surface.setLayoutParams(new FrameLayout.LayoutParams(initial.width(),initial.height()));
        positionSurface();updateLabels();root.requestLayout();root.invalidate();
    }

    private void cancelGeometry() {
        android.animation.ValueAnimator previous = geometry;
        geometry = null;
        if (previous != null) previous.cancel();
    }
    private void stopGeometry() {
        stopHandleFling();
        if(geometry==null)return;
        cancelGeometry();commitVisualWindow();
    }
    private void commitVisualWindow() {
        layout.x=visualBounds.left;layout.y=visualBounds.top;
        layout.width=visualBounds.width();layout.height=visualBounds.height();
        surface.setLayoutParams(new FrameLayout.LayoutParams(layout.width,layout.height));
        surfaceAnchored=true;windows.updateViewLayout(root,layout);positionSurface();
    }
    private void positionSurface() {
        int[] origin=new int[2];root.getLocationOnScreen(origin);
        surface.setTranslationX(visualBounds.left-origin[0]);surface.setTranslationY(visualBounds.top-origin[1]);
        if(geometry==null && origin[0]==visualBounds.left && origin[1]==visualBounds.top &&
            root.getWidth()==visualBounds.width() && root.getHeight()==visualBounds.height())surfaceAnchored=false;
    }
    private void styleSurface() {
        surface.setBackground(shape(glass(appearance.surface,Math.round(0x99*expansion)),Math.round(6+12*expansion)));
        // Overlay-window elevation casts a second translucent slab outside the
        // glass surface on OEM compositors. Keep only the rounded glass itself.
        surface.setElevation(0);
    }
    private void finishGeometry(boolean small) {
        expansion=small?0:1;
        expanded.setVisibility(small ? View.GONE : View.VISIBLE);
        handle.setVisibility(small ? View.VISIBLE : View.GONE);
        expanded.setAlpha(1); handle.setAlpha(1);
        handle.setEnabled(true); handle.setClickable(true);
        styleSurface();
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
        shelf.setVisibleSuggestions(java.util.Collections.emptySet());
        main.removeCallbacks(suggestionScrollIdle);
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
            if(!mainMediaActive)mediaSuggestions.stop();
            context.unregisterComponentCallbacks(configurationChanges);
            context.unregisterReceiver(screenChanges);
            if (appearanceChanges != null) { appearanceChanges.stopWatching(); appearanceChanges = null; }
            stopGeometry();
            releaseHandleVelocity();
            savePlacement();
            cancelPendingOpen();
            main.removeCallbacks(countdown);
            stopTargetScroll();
            if (dragExpand != null) main.removeCallbacks(dragExpand);
            dragExpand = null;
            final View leaving = root;
            final FrameLayout leavingSurface=surface;
            final Rect leavingBounds=new Rect(visualBounds);
            final WindowManager.LayoutParams leavingLayout = layout;
            final boolean registered = rootAdded;
            root = null; surface=null; expanded = null; rail=null; row = null; scroll = null; count = null; layout = null;
            header = null; handle = null; shelfTab = null; contentGestures=null;
            countGroup=null;shelfGroup=null;countIcon=null;shelfIcon=null;
            targetScroll=null;targetRow=null;forwarding=null;hoveredTarget=null;
            suggestionTouch=false;suggestionDrag=false;suggestionScrolling=false;
            shelf.suggestionInteraction("overlay",false);
            rootAdded = false;
            leaving.animate().cancel();
            leaving.setScaleX(1);leaving.setScaleY(1);
            if (registered && leaving.isAttachedToWindow()) {
                leaving.getViewTreeObserver().addOnPreDrawListener(() -> {
                    int[] origin=new int[2];leaving.getLocationOnScreen(origin);
                    leavingSurface.setTranslationX(leavingBounds.left-origin[0]+leaving.getTranslationX());
                    leavingSurface.setTranslationY(leavingBounds.top-origin[1]);return true;
                });
                leavingLayout.flags |= WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE;
                windows.updateViewLayout(leaving, leavingLayout);
                leaving.animate().alpha(0).translationX(dp(20))
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
    private LinearLayout countTab(TextView number,ImageView icon,Runnable action) {
        LinearLayout group=new LinearLayout(context);group.setOrientation(LinearLayout.HORIZONTAL);group.setGravity(Gravity.CENTER);
        number.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        icon.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        group.addView(number,new LinearLayout.LayoutParams(-2,-1));
        LinearLayout.LayoutParams iconSize=new LinearLayout.LayoutParams(dp(18),dp(18));iconSize.leftMargin=dp(4);
        group.addView(icon,iconSize);group.setOnClickListener(view -> action.run());
        return group;
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
            if(Build.VERSION.SDK_INT>=29 && path.startsWith("content://media/"))
                return context.getContentResolver().loadThumbnail(android.net.Uri.parse(path),new android.util.Size(size,size),null);
            if(path.toLowerCase(java.util.Locale.ROOT).matches(".*\\.(mp4|mov|m4v|webm|mkv|3gp)$")) {
                try(android.media.MediaMetadataRetriever video=new android.media.MediaMetadataRetriever()) {
                    if(path.startsWith("content://"))video.setDataSource(context,android.net.Uri.parse(path));
                    else video.setDataSource(path);
                    return Build.VERSION.SDK_INT>=27?
                        video.getScaledFrameAtTime(-1,android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC,size,size):
                        video.getFrameAtTime();
                }
            }
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
