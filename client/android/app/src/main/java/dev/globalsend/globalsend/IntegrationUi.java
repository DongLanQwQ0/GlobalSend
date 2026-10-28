package dev.globalsend.globalsend;

import android.app.Activity;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/** Native consent surfaces share the installed appearance without loading Flutter. */
final class IntegrationUi {
    final Activity activity;
    final ReceiveAppearance colors;
    final LinearLayout body;
    IntegrationUi(Activity activity,String title) {
        this.activity=activity;colors=ReceiveAppearance.load(activity);
        activity.setTitle(title);activity.getWindow().setStatusBarColor(colors.surface);activity.getWindow().setNavigationBarColor(colors.surface);
        activity.getWindow().getDecorView().setSystemUiVisibility("dark".equals(mode())?0:View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR|View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        ScrollView scroll=new ScrollView(activity);scroll.setFillViewport(true);scroll.setBackgroundColor(colors.surface);
        body=new LinearLayout(activity);body.setOrientation(LinearLayout.VERTICAL);body.setPadding(dp(24),dp(24),dp(24),dp(24));
        scroll.addView(body,new ScrollView.LayoutParams(-1,-2));activity.setContentView(scroll);
        LinearLayout heading=new LinearLayout(activity);heading.setGravity(Gravity.CENTER_VERTICAL);
        TextView label=text(title,24,colors.ink);label.setTypeface(null,android.graphics.Typeface.BOLD);
        heading.addView(label,new LinearLayout.LayoutParams(0,dp(48),1));
        Button close=button("关闭",false,activity::finish);heading.addView(close,new LinearLayout.LayoutParams(dp(72),dp(48)));
        body.addView(heading);space(24);
    }
    private String mode() { return colors.surface==0xff202124?"dark":"light"; }
    int dp(int value) { return Math.round(value*activity.getResources().getDisplayMetrics().density); }
    TextView text(String value,int size,int color) {
        TextView view=new TextView(activity);view.setText(value);view.setTextSize(size);view.setTextColor(color);view.setLineSpacing(dp(4),1);return view;
    }
    void paragraph(String value) { body.addView(text(value,16,colors.muted));space(20); }
    void space(int value) { body.addView(new View(activity),new LinearLayout.LayoutParams(-1,dp(value))); }
    GradientDrawable shape(int color) { GradientDrawable shape=new GradientDrawable();shape.setColor(color);shape.setCornerRadius(dp(14));return shape; }
    Button button(String title,boolean primary,Runnable clicked) {
        Button button=new Button(activity);button.setText(title);button.setTextSize(16);button.setAllCaps(false);
        button.setTextColor(primary ? (colors.surface==0xff202124?0xff16191d:0xffffffff) : colors.accent);
        button.setBackground(shape(primary?colors.accent:colors.soft));button.setOnClickListener(view->clicked.run());return button;
    }
}
