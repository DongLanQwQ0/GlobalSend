package dev.globalsend.globalsend;

import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import java.io.File;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Package bytes are copied on the dock worker, never installed, modified or re-signed. */
final class InstalledApps {
    static List<Map<String,Object>> list(Context context) throws Exception {
        PackageManager pm = context.getPackageManager();
        Map<String,Map<String,Object>> unique = new LinkedHashMap<>();
        for (ResolveInfo resolved : pm.queryIntentActivities(new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)) {
            String id = resolved.activityInfo.packageName;
            if (unique.containsKey(id)) continue;
            PackageInfo info = pm.getPackageInfo(id, 0);
            ApplicationInfo app = info.applicationInfo;
            Map<String,Object> value = new HashMap<>();
            value.put("package", id); value.put("name", pm.getApplicationLabel(app).toString());
            value.put("version", info.versionName == null ? "" : info.versionName);
            value.put("apkCount", 1 + (app.splitSourceDirs == null ? 0 : app.splitSourceDirs.length));
            android.graphics.drawable.Drawable drawable = pm.getApplicationIcon(app);
            android.graphics.Bitmap icon = android.graphics.Bitmap.createBitmap(64,64,android.graphics.Bitmap.Config.ARGB_8888);
            drawable.setBounds(0,0,64,64); drawable.draw(new android.graphics.Canvas(icon));
            java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
            icon.compress(android.graphics.Bitmap.CompressFormat.PNG,100,bytes); icon.recycle();
            value.put("icon", bytes.toByteArray()); unique.put(id,value);
        }
        List<Map<String,Object>> apps = new ArrayList<>(unique.values());
        java.text.Collator collator = java.text.Collator.getInstance();
        apps.sort((a,b)->collator.compare((String)a.get("name"),(String)b.get("name")));
        return apps;
    }

    static Map<String,Object> export(Context context,String id) throws Exception {
        PackageInfo info = context.getPackageManager().getPackageInfo(id,0);
        ApplicationInfo app = info.applicationInfo;
        String label = context.getPackageManager().getApplicationLabel(app).toString();
        String name = (label + (info.versionName == null ? "" : "-" + info.versionName)).replaceAll("[\\\\/:*?\"<>|\\p{Cntrl}]", "_");
        List<String> sources = new ArrayList<>(); sources.add(app.sourceDir);
        if (app.splitSourceDirs != null) java.util.Collections.addAll(sources, app.splitSourceDirs);
        File parent = new File(context.getFilesDir(),"exported-apps/" + UUID.randomUUID());
        if (!parent.mkdirs()) throw new java.io.IOException("无法创建应用导出目录");
        File target = new File(parent, name + (sources.size() == 1 ? ".apk" : ""));
        if (sources.size() > 1 && !target.mkdir()) throw new java.io.IOException("无法创建 APK 组合目录");
        for (int i=0;i<sources.size();i++) {
            File source = new File(sources.get(i));
            File destination = sources.size() == 1 ? target : new File(target, i == 0 ? "base.apk" : source.getName());
            Files.copy(source.toPath(),destination.toPath());
        }
        Map<String,Object> result = new HashMap<>();
        result.put("path", target.getPath()); result.put("apkCount", sources.size()); return result;
    }
}
