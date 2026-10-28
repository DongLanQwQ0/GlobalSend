package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Map;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk=34, manifest=Config.NONE)
public class InstalledAppsTest {
    @Test public void singleApkIsNamedAndSplitAppKeepsEveryApkAsARealDirectory() throws Exception {
        Context context=RuntimeEnvironment.getApplication();
        File base=new File(context.getFilesDir(),"installed-base.apk"),split=new File(context.getFilesDir(),"split_config.arm64_v8a.apk");
        Files.write(base.toPath(),"base".getBytes(StandardCharsets.UTF_8));Files.write(split.toPath(),"split".getBytes(StandardCharsets.UTF_8));
        PackageInfo app=new PackageInfo();app.packageName="test.shareable";app.versionName="1.2";
        app.applicationInfo=new ApplicationInfo();app.applicationInfo.packageName=app.packageName;app.applicationInfo.nonLocalizedLabel="示例应用";app.applicationInfo.sourceDir=base.getPath();
        Shadows.shadowOf(context.getPackageManager()).installPackage(app);
        Map<String,Object> single=InstalledApps.export(context,app.packageName);File apk=new File((String)single.get("path"));
        assertEquals("示例应用-1.2.apk",apk.getName());assertEquals(1,single.get("apkCount"));assertTrue(apk.isFile());
        app.applicationInfo.splitSourceDirs=new String[]{split.getPath()};Shadows.shadowOf(context.getPackageManager()).installPackage(app);
        Map<String,Object> multiple=InstalledApps.export(context,app.packageName);File folder=new File((String)multiple.get("path"));
        assertTrue(folder.isDirectory());assertEquals(2,multiple.get("apkCount"));assertEquals(2,folder.list().length);
        assertEquals("base",new String(Files.readAllBytes(new File(folder,"base.apk").toPath()),StandardCharsets.UTF_8));
        assertEquals("split",new String(Files.readAllBytes(new File(folder,split.getName()).toPath()),StandardCharsets.UTF_8));
        assertTrue(base.exists());assertTrue(split.exists());
    }
}
