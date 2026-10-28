package dev.globalsend.globalsend;

/** Notification PendingIntent target; an Activity, never a service trampoline. */
public final class IntegrationUrlActivity extends android.app.Activity {
    @Override public void onCreate(android.os.Bundle state) {
        super.onCreate(state);
        String token=getIntent().getData()==null?null:getIntent().getData().getLastPathSegment();
        IntegrationUrlRequests.get(this).clicked(this,token);
    }
}
