package dev.globalsend.globalsend;

import android.app.Activity;
import android.content.ClipData;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import androidx.core.content.FileProvider;
import java.io.File;
import java.io.IOException;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;

/** Validates a self-update off the UI thread, then hands consent to Android. */
final class AndroidAppUpdateInstaller {
    static final class Package {
        final File file;
        final long version;
        Package(File file, long version) { this.file = file; this.version = version; }
    }

    @SuppressWarnings("deprecation")
    static Package inspect(Context context, String path, String expectedVersion, Number expectedBuild) throws Exception {
        if (path == null) throw new IOException("更新文件不存在，请重新下载");
        File file = new File(path).getCanonicalFile();
        if (!file.isFile() || !file.canRead() || file.length() == 0)
            throw new IOException("更新文件不存在，请重新下载");
        PackageManager manager = context.getPackageManager();
        int flags = Build.VERSION.SDK_INT >= 28 ? PackageManager.GET_SIGNING_CERTIFICATES : PackageManager.GET_SIGNATURES;
        PackageInfo candidate = manager.getPackageArchiveInfo(file.getPath(), flags);
        PackageInfo installed = manager.getPackageInfo(context.getPackageName(), flags);
        if (candidate == null || !context.getPackageName().equals(candidate.packageName))
            throw new IllegalArgumentException("该安装包不是 GlobalSend 更新");
        long version = version(candidate);
        if (version <= version(installed)) throw new IllegalArgumentException("该版本已安装，无需更新");
        if (expectedBuild != null && expectedBuild.longValue() > 0 && expectedBuild.longValue() != version ||
                expectedVersion != null && !expectedVersion.isEmpty() && !expectedVersion.equals(candidate.versionName))
            throw new IllegalArgumentException("更新文件与发布版本不一致，请重新下载");
        if (!sameSigner(installed, candidate))
            throw new IllegalArgumentException("安装包签名与当前版本不一致，无法保留数据更新");
        return new Package(file, version);
    }

    @SuppressWarnings("deprecation")
    static long version(PackageInfo info) {
        return Build.VERSION.SDK_INT >= 28 ? info.getLongVersionCode() : info.versionCode;
    }

    @SuppressWarnings("deprecation")
    private static boolean sameSigner(PackageInfo installed, PackageInfo candidate) {
        if (Build.VERSION.SDK_INT >= 28 && installed.signingInfo != null && candidate.signingInfo != null) {
            Signature[] current = installed.signingInfo.getApkContentsSigners();
            Signature[] next = candidate.signingInfo.getApkContentsSigners();
            if (current == null || next == null || current.length == 0 || next.length == 0) return false;
            if (installed.signingInfo.hasMultipleSigners() || candidate.signingInfo.hasMultipleSigners())
                return new HashSet<>(Arrays.asList(current)).equals(new HashSet<>(Arrays.asList(next)));
            // A valid rotation lineage still contains the installed signing cert.
            Signature[] history = candidate.signingInfo.getSigningCertificateHistory();
            return Arrays.asList(history == null ? next : history).contains(current[0]);
        }
        Signature[] current = installed.signatures, next = candidate.signatures;
        return current != null && next != null && current.length > 0 && next.length > 0 &&
            new HashSet<>(Arrays.asList(current)).equals(new HashSet<>(Arrays.asList(next)));
    }

    static Map<String, Object> launch(Context context, Activity activity, Package update, boolean explicit) {
        return launch(context, activity, update, explicit, (owner, file) ->
            FileProvider.getUriForFile(owner, owner.getPackageName() + ".updates", file));
    }
    interface UriResolver { Uri resolve(Context context, File file); }
    static Map<String, Object> launch(Context context, Activity activity, Package update, boolean explicit, UriResolver source) {
        if (activity == null || activity.isFinishing() || activity.isDestroyed())
            return state("ready", "更新已下载，打开 GlobalSend 后即可安装");
        if (Build.VERSION.SDK_INT >= 26 && !context.getPackageManager().canRequestPackageInstalls()) {
            SharedPreferences preferences = context.getSharedPreferences("app-updates", Context.MODE_PRIVATE);
            String identity = update.file.getPath() + ":" + update.version;
            if (explicit || !identity.equals(preferences.getString("permissionRequested", ""))) {
                activity.startActivity(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:" + context.getPackageName())));
                preferences.edit().putString("permissionRequested", identity).apply();
            }
            return state("permission-required", "允许 GlobalSend 安装应用后即可继续");
        }
        Uri uri = source.resolve(context, update.file);
        activity.startActivity(installIntent(uri));
        context.getSystemService(android.app.NotificationManager.class).cancel(AppUpdateNotifications.ID);
        context.getSharedPreferences("app-updates", Context.MODE_PRIVATE).edit().remove("permissionRequested").apply();
        return state("started", "请在系统安装界面确认更新");
    }

    static Intent installIntent(Uri uri) {
        Intent intent = new Intent(Intent.ACTION_VIEW).setDataAndType(uri, AndroidFileOpener.APK)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        intent.setClipData(ClipData.newRawUri("GlobalSend 更新", uri));
        return intent;
    }

    private static Map<String, Object> state(String state, String message) {
        Map<String, Object> value = new HashMap<>();
        value.put("state", state); value.put("message", message);
        return value;
    }
}
