package dev.globalsend.globalsend;

import android.app.Activity;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Opened only by GlobalSend's immutable one-shot consent PendingIntent. */
public final class IntegrationAssociationActivity extends Activity {
    private String token;
    private IntegrationAssociations associations;
    private boolean approved;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        associations=new IntegrationAssociations(this);
        token=getIntent().getData()==null?null:getIntent().getData().getLastPathSegment();
        IntegrationAssociations.Caller caller=token==null?null:associations.pending(token);
        IntegrationUi ui=new IntegrationUi(this,"应用联动");
        if(caller==null) { ui.paragraph("关联请求已失效，请回到拾时重新连接。");return; }
        LinearLayout identity=new LinearLayout(this);identity.setGravity(Gravity.CENTER_VERTICAL);
        ImageView icon=new ImageView(this);
        try {icon.setImageDrawable(getPackageManager().getApplicationIcon(caller.packageName));}catch(android.content.pm.PackageManager.NameNotFoundException removed) {finish();return;}
        identity.addView(icon,new LinearLayout.LayoutParams(ui.dp(48),ui.dp(48)));
        TextView app=ui.text(caller.label,20,ui.colors.ink);app.setTypeface(null,android.graphics.Typeface.BOLD);app.setPadding(ui.dp(16),0,0,0);
        identity.addView(app,new LinearLayout.LayoutParams(0,-2,1));ui.body.addView(identity);ui.space(24);
        ui.paragraph("允许此应用通过 GlobalSend：");
        LinearLayout permissions=new LinearLayout(this);permissions.setOrientation(LinearLayout.VERTICAL);permissions.setPadding(ui.dp(20),ui.dp(16),ui.dp(20),ui.dp(16));permissions.setBackground(ui.shape(ui.colors.field));
        permissions.addView(ui.text("读取本组设备",17,ui.colors.ink));
        TextView send=ui.text("发送所选网页",17,ui.colors.ink);send.setPadding(0,ui.dp(14),0,0);permissions.addView(send);
        ui.body.addView(permissions);ui.space(20);
        ui.paragraph("不共享组密码或账号。可随时在 GlobalSend 的应用联动中撤销。");
        LinearLayout actions=new LinearLayout(this);
        actions.addView(ui.button("拒绝",false,()->{associations.reject(token);setResult(RESULT_CANCELED);finish();}),new LinearLayout.LayoutParams(0,ui.dp(48),1));
        android.view.View gap=new android.view.View(this);actions.addView(gap,new LinearLayout.LayoutParams(ui.dp(12),1));
        actions.addView(ui.button("允许",true,()->{
            if(associations.approve(token)) {approved=true;setResult(RESULT_OK);finish();}
            else {android.widget.Toast.makeText(this,"关联请求已失效，请重试",android.widget.Toast.LENGTH_SHORT).show();finish();}
        }),new LinearLayout.LayoutParams(0,ui.dp(48),1));
        ui.body.addView(actions);
    }
    @Override protected void onDestroy() {
        if(isFinishing()&&!approved&&token!=null&&associations!=null) associations.reject(token);
        super.onDestroy();
    }
}
