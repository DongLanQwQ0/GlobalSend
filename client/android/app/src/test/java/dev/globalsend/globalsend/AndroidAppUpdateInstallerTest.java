package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.ProviderInfo;
import android.content.pm.Signature;
import android.content.pm.SigningInfo;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.provider.Settings;
import androidx.core.content.FileProvider;
import java.io.File;
import java.io.FileInputStream;
import java.nio.file.Files;
import org.junit.Before;
import org.junit.Assume;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowContentResolver;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34, manifest = Config.NONE)
public class AndroidAppUpdateInstallerTest {
    private Activity activity;
    private PackageManager manager;
    private File apk;
    private final Signature certificate = new Signature("010203");

    @Before public void setup() throws Exception {
        activity = Robolectric.buildActivity(Activity.class).setup().get();
        manager = activity.getPackageManager();
        PackageInfo installed = manager.getPackageInfo(activity.getPackageName(), 0);
        installed.versionName = "1.0.77"; installed.setLongVersionCode(101);
        installed.signingInfo = signing(certificate);
        Shadows.shadowOf(manager).installPackage(installed);
        File directory = new File(activity.getFilesDir(), "updates"); directory.mkdirs();
        apk = new File(directory, "GlobalSend-1.0.79-android-arm64-v8a.apk");
        Files.write(apk.toPath(), new byte[]{7, 8, 9});
        Shadows.shadowOf(manager).setPackageArchiveInfo(apk.getCanonicalPath(), candidate(activity.getPackageName(), 103, certificate));
        Shadows.shadowOf(manager).setCanRequestPackageInstalls(true);
    }
    private SigningInfo signing(Signature signature) {
        SigningInfo value = new SigningInfo();
        Shadows.shadowOf(value).setSignatures(new Signature[]{signature});
        return value;
    }
    private PackageInfo candidate(String name, long build, Signature signature) {
        PackageInfo value = new PackageInfo(); value.packageName = name;
        value.versionName = "1.0.79"; value.setLongVersionCode(build);
        value.signingInfo = signing(signature); return value;
    }
    private AndroidAppUpdateInstaller.Package inspect() throws Exception {
        return AndroidAppUpdateInstaller.inspect(activity, apk.getPath(), "1.0.79", 103);
    }
    private FileProvider provider() {
        ProviderInfo info = new ProviderInfo();
        info.authority = activity.getPackageName() + ".updates";
        info.name = FileProvider.class.getName(); info.packageName = activity.getPackageName();
        info.applicationInfo = activity.getApplicationInfo(); info.exported = false; info.grantUriPermissions = true;
        info.metaData = new Bundle(); info.metaData.putInt("android.support.FILE_PROVIDER_PATHS", R.xml.update_paths);
        Shadows.shadowOf(manager).addOrUpdateProvider(info);
        FileProvider provider = new FileProvider(); provider.attachInfo(activity, info);
        ShadowContentResolver.registerProviderInternal(info.authority, provider); return provider;
    }
    private java.util.Map<String, Object> launch(AndroidAppUpdateInstaller.Package update, boolean explicit) {
        // AndroidX's private path mapper uses '/' (as Android does); the host
        // JVM here uses '\\'. Replace only that OS boundary in Windows tests.
        return AndroidAppUpdateInstaller.launch(activity, activity, update, explicit, (context, file) -> {
            assertTrue(file.toPath().startsWith(new File(context.getFilesDir(), "updates").toPath()));
            return new Uri.Builder().scheme("content").authority(context.getPackageName() + ".updates")
                .appendPath("updates").appendPath(file.getName()).build();
        });
    }
    @Test public void matchingNewerSignedPackageOpensSystemInstallerWithContentReadGrant() throws Exception {
        AndroidAppUpdateInstaller.Package update = inspect();
        assertEquals("started", launch(update, false).get("state"));
        Intent intent = Shadows.shadowOf(activity).getNextStartedActivity();
        assertEquals(Intent.ACTION_VIEW, intent.getAction());
        assertEquals(AndroidFileOpener.APK, intent.getType());
        assertEquals("content", intent.getData().getScheme());
        assertEquals(activity.getPackageName() + ".updates", intent.getData().getAuthority());
        assertEquals(intent.getData(), intent.getClipData().getItemAt(0).getUri());
        assertTrue((intent.getFlags() & Intent.FLAG_GRANT_READ_URI_PERMISSION) != 0);
        assertArrayEquals(new byte[]{7, 8, 9}, Files.readAllBytes(apk.toPath()));
        assertTrue(apk.isFile());
    }
    @Test public void missingInstallPermissionOpensSettingsOnceThenResumesWithoutPromptLoop() throws Exception {
        AndroidAppUpdateInstaller.Package update = inspect();
        Shadows.shadowOf(manager).setCanRequestPackageInstalls(false);
        assertEquals("permission-required", launch(update, false).get("state"));
        Intent permission = Shadows.shadowOf(activity).getNextStartedActivity();
        assertEquals(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, permission.getAction());
        assertEquals("package:" + activity.getPackageName(), permission.getDataString());
        assertEquals("permission-required", launch(update, false).get("state"));
        assertNull(Shadows.shadowOf(activity).getNextStartedActivity());
        launch(update, true);
        assertEquals(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Shadows.shadowOf(activity).getNextStartedActivity().getAction());
        Shadows.shadowOf(manager).setCanRequestPackageInstalls(true);
        assertEquals("started", launch(update, false).get("state"));
        assertEquals(AndroidFileOpener.APK, Shadows.shadowOf(activity).getNextStartedActivity().getType());
    }
    @Test public void backgroundReadyDoesNotLaunchInstallerOrSettings() throws Exception {
        assertEquals("ready", AndroidAppUpdateInstaller.launch(activity, null, inspect(), false).get("state"));
        assertNull(Shadows.shadowOf(activity).getNextStartedActivity());
    }
    @Test public void wrongPackageOrSignerOrOldVersionNeverStartsInstallation() throws Exception {
        for (PackageInfo candidate : new PackageInfo[]{
                candidate("another.app", 103, certificate),
                candidate(activity.getPackageName(), 103, new Signature("040506")),
                candidate(activity.getPackageName(), 101, certificate),
                candidate(activity.getPackageName(), 104, certificate)}) {
            Shadows.shadowOf(manager).setPackageArchiveInfo(apk.getCanonicalPath(), candidate);
            try { inspect(); fail("Not a matching, newer self-update"); }
            catch (IllegalArgumentException expected) { }
        }
        assertNull(Shadows.shadowOf(activity).getNextStartedActivity());
    }
    @Test public void signingRotationRetainsAuthorizedInstalledCertificate() throws Exception {
        PackageInfo candidate = candidate(activity.getPackageName(), 103, new Signature("040506"));
        Shadows.shadowOf(candidate.signingInfo).setPastSigningCertificates(new Signature[]{certificate, new Signature("040506")});
        Shadows.shadowOf(manager).setPackageArchiveInfo(apk.getCanonicalPath(), candidate);
        assertEquals(103, inspect().version);
    }
    @Test public void platformFileProviderServesStableReadableApkOnAndroidStyleFilesystem() throws Exception {
        Assume.assumeTrue("AndroidX FileProvider uses Android '/' path separators", File.separatorChar == '/');
        FileProvider provider = provider();
        Uri uri = FileProvider.getUriForFile(activity, activity.getPackageName() + ".updates", apk);
        try (ParcelFileDescriptor fd = provider.openFile(uri, "r")) {
            assertArrayEquals(new byte[]{7, 8, 9}, new FileInputStream(fd.getFileDescriptor()).readAllBytes());
        }
    }
}
