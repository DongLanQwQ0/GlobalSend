package dev.globalsend.globalsend;

import android.app.Activity;
import android.os.Bundle;
import android.widget.LinearLayout;
import android.widget.TextView;
import org.json.JSONObject;

public final class IntegrationAssociationsActivity extends Activity {
    @Override public void onCreate(Bundle state) {super.onCreate(state);render();}
    private void render() {
        IntegrationUi ui=new IntegrationUi(this,"应用联动");
        IntegrationAssociations store=new IntegrationAssociations(this);JSONObject record=store.record("grant");
        if(record==null) {ui.paragraph("暂无关联应用");return;}
        boolean valid=store.authorized(store.caller(record.optInt("uid",-1)));
        LinearLayout row=new LinearLayout(this);row.setGravity(android.view.Gravity.CENTER_VERTICAL);row.setPadding(ui.dp(16),ui.dp(12),ui.dp(16),ui.dp(12));row.setBackground(ui.shape(ui.colors.field));
        LinearLayout description=new LinearLayout(this);description.setOrientation(LinearLayout.VERTICAL);
        description.addView(ui.text(record.optString("label","拾时"),18,ui.colors.ink));
        TextView status=ui.text(valid?"读取本组设备 · 发送所选网页":"关联已失效",13,ui.colors.muted);status.setPadding(0,ui.dp(8),ui.dp(12),0);description.addView(status);
        row.addView(description,new LinearLayout.LayoutParams(0,-2,1));
        row.addView(ui.button("撤销",false,()->{store.revoke();render();}),new LinearLayout.LayoutParams(ui.dp(72),ui.dp(48)));
        ui.body.addView(row);
    }
}
