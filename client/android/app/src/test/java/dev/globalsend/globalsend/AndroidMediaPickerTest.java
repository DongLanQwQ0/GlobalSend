package dev.globalsend.globalsend;

import static org.junit.Assert.*;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.Intent;
import android.content.pm.ProviderInfo;
import android.net.Uri;
import android.os.Looper;
import android.provider.MediaStore;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.FlutterException;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMethodCodec;
import java.io.File;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowContentResolver;

/** Framework contract/import tests; device picker appearance is release acceptance. */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28, manifest = Config.NONE)
public class AndroidMediaPickerTest {
    private PickerActivity activity;
    private DockCoordinator coordinator;
    private BinaryMessenger.BinaryMessageHandler handler;
    private final List<MethodCall> events = new CopyOnWriteArrayList<>();

    @Before public void setup() {
        activity = Robolectric.buildActivity(PickerActivity.class).setup().get();
        BinaryMessenger messenger = new BinaryMessenger() {
            @Override public void send(String channel, ByteBuffer message) { send(channel, message, null); }
            @Override public void send(String channel, ByteBuffer message, BinaryReply reply) {
                ByteBuffer copy = message.duplicate(); copy.flip();
                events.add(StandardMethodCodec.INSTANCE.decodeMethodCall(copy));
            }
            @Override public void setMessageHandler(String channel, BinaryMessageHandler value) { handler = value; }
        };
        coordinator = new DockCoordinator(activity, new MethodChannel(messenger, "test-media"));
        call("pending");
    }

    @After public void teardown() {
        coordinator.dispose(); activity.finish();
    }

    private Reply call(String method) {
        ByteBuffer request = StandardMethodCodec.INSTANCE.encodeMethodCall(new MethodCall(method, null));
        request.flip(); Reply result = new Reply();
        handler.onMessage(request, response -> {
            ByteBuffer copy = response.duplicate(); copy.flip();
            try { result.value = StandardMethodCodec.INSTANCE.decodeEnvelope(copy); }
            catch (FlutterException error) { result.error = error.code; }
            result.calls++;
        });
        return result;
    }

    @Test @Config(sdk = 34)
    public void systemPhotoPickerAcceptsBothKindsWithoutStoragePermissionOrTranscoding() {
        Reply result = call("pickMedia");
        org.robolectric.shadows.ShadowActivity.IntentForResult launched = Shadows.shadowOf(activity).getNextStartedActivityForResult();
        assertEquals(DockCoordinator.PICK_SEND_MEDIA, launched.requestCode);
        assertEquals(MediaStore.ACTION_PICK_IMAGES, launched.intent.getAction());
        assertNull(launched.intent.getType()); // Android's default is images AND videos.
        assertEquals(32, launched.intent.getIntExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, 0));
        assertFalse(launched.intent.hasExtra("android.provider.extra.MEDIA_CAPABILITIES"));
        assertEquals(0, result.calls);
        coordinator.onActivityResult(DockCoordinator.PICK_SEND_MEDIA, Activity.RESULT_CANCELED, null);
        assertEquals(1, result.calls); assertNull(result.error);
    }

    @Test public void oldAndroidUsesOfficialImageVideoFallbackAndCancelDoesNotImport() {
        Reply first = call("pickMedia");
        Intent launched = Shadows.shadowOf(activity).getNextStartedActivityForResult().intent;
        assertEquals(Intent.ACTION_OPEN_DOCUMENT, launched.getAction());
        assertTrue(launched.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false));
        assertArrayEquals(new String[]{"image/*", "video/*"}, launched.getStringArrayExtra(Intent.EXTRA_MIME_TYPES));
        Reply duplicate = call("pickMedia");
        assertEquals("DOCK_UNAVAILABLE", duplicate.error);
        assertFalse(coordinator.onActivityResult(123, Activity.RESULT_CANCELED, null));
        assertTrue(coordinator.onActivityResult(DockCoordinator.PICK_SEND_MEDIA, Activity.RESULT_CANCELED, null));
        assertEquals(1, first.calls); assertNull(first.error);
        assertEquals(false, coordinator.status().get("importing"));
        assertTrue(events.isEmpty());
        assertEquals(List.of(), call("pending").value);
        Reply next = call("pickMedia");
        coordinator.onActivityResult(DockCoordinator.PICK_SEND_MEDIA, Activity.RESULT_OK, new Intent());
        assertEquals(1, next.calls); assertNull(next.error);
    }

    @Test public void imageAndVideoAreCopiedByteForByteOnceAndRecoverThroughPending() throws Exception {
        AndroidDragTest.FixtureProvider provider = new AndroidDragTest.FixtureProvider();
        provider.directory = new File(activity.getCacheDir(), "media-fixtures"); provider.directory.mkdirs();
        byte[] photo = new byte[]{12, 23, 34, 45}, video = new byte[150000]; video[149999] = 99;
        Files.write(new File(provider.directory, "照片.heic").toPath(), photo);
        Files.write(new File(provider.directory, "视频.mp4").toPath(), video);
        ProviderInfo info = new ProviderInfo(); info.authority = "media-fixtures"; provider.attachInfo(activity, info);
        ShadowContentResolver.registerProviderInternal(info.authority, provider);
        Uri image = new Uri.Builder().scheme("content").authority(info.authority).appendPath("照片.heic").build();
        Uri movie = new Uri.Builder().scheme("content").authority(info.authority).appendPath("视频.mp4").build();
        ClipData clip = new ClipData("media", new String[]{"image/heic", "video/mp4"}, new ClipData.Item(image));
        clip.addItem(new ClipData.Item(movie)); clip.addItem(new ClipData.Item(image));
        Intent selected = new Intent().setData(image).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        selected.setClipData(clip);
        Reply result = call("pickMedia");
        coordinator.onActivityResult(DockCoordinator.PICK_SEND_MEDIA, Activity.RESULT_OK, selected);
        assertEquals(1, result.calls); assertNull(result.error);
        Map<?, ?> drop = awaitDrop();
        assertNull(drop.get("error"));
        List<?> paths = (List<?>) drop.get("paths"); assertEquals(2, paths.size());
        assertArrayEquals(photo, Files.readAllBytes(new File((String) paths.get(0)).toPath()));
        assertArrayEquals(video, Files.readAllBytes(new File((String) paths.get(1)).toPath()));
        assertEquals("照片.heic", new File((String) paths.get(0)).getName());
        assertEquals("视频.mp4", new File((String) paths.get(1)).getName());
        assertEquals(paths, drop.get("temporaryPaths"));
        List<?> pending = (List<?>) call("pending").value; assertEquals(1, pending.size());
        assertEquals(drop.get("dropId"), ((Map<?, ?>) pending.get(0)).get("dropId"));
        assertEquals(List.of(), call("pending").value);
        coordinator.onActivityResult(DockCoordinator.PICK_SEND_MEDIA, Activity.RESULT_OK, selected);
        assertEquals(1, events.stream().filter(event -> event.method.equals("nativeDrop")).count());
        assertEquals(false, coordinator.status().get("importing"));
    }

    @Test public void fallbackOverLimitAndMalformedUriFailWithoutPartialImport() {
        Reply first = call("pickMedia");
        ClipData clip = new ClipData("many", new String[]{"video/mp4"}, new ClipData.Item(Uri.parse("content://media/0")));
        for (int i = 1; i < 33; i++) clip.addItem(new ClipData.Item(Uri.parse("content://media/" + i)));
        Intent selected = new Intent(); selected.setClipData(clip);
        coordinator.onActivityResult(DockCoordinator.PICK_SEND_MEDIA, Activity.RESULT_OK, selected);
        assertEquals("MEDIA_IMPORT_FAILED", first.error); assertEquals(1, first.calls);
        Reply second = call("pickMedia");
        coordinator.onActivityResult(DockCoordinator.PICK_SEND_MEDIA, Activity.RESULT_OK, new Intent().setData(Uri.parse("file:///not-granted.mp4")));
        assertEquals("MEDIA_IMPORT_FAILED", second.error); assertEquals(1, second.calls);
        assertTrue(events.isEmpty()); assertEquals(List.of(), call("pending").value);
    }

    @Test public void unreadableSourceReportsImportErrorAndEndsImporting() throws Exception {
        Reply result = call("pickMedia");
        coordinator.onActivityResult(DockCoordinator.PICK_SEND_MEDIA, Activity.RESULT_OK, new Intent().setData(Uri.parse("content://missing/source.mp4")));
        assertEquals(1, result.calls);
        Map<?, ?> drop = awaitDrop();
        assertNotNull(drop.get("error")); assertEquals(List.of(), drop.get("paths"));
        assertEquals(false, coordinator.status().get("importing"));
    }

    @Test public void configurationReplacementKeepsRequestAndNewHostCanFinishIt() {
        Reply result = call("pickMedia");
        activity.changing = true;
        coordinator.detach(activity);
        assertEquals(0, result.calls);
        PickerActivity replacement = Robolectric.buildActivity(PickerActivity.class).setup().get();
        coordinator.attach(replacement);
        coordinator.onActivityResult(DockCoordinator.PICK_SEND_MEDIA, Activity.RESULT_CANCELED, null);
        assertEquals(1, result.calls); assertNull(result.error);
        replacement.finish();
    }

    @Test public void finishingHostOrDisposingCompletesRequestAndIgnoresOrphanResult() {
        Reply first = call("pickMedia");
        coordinator.detach(activity);
        assertEquals("MEDIA_PICKER_CLOSED", first.error); assertEquals(1, first.calls);
        coordinator.onActivityResult(DockCoordinator.PICK_SEND_MEDIA, Activity.RESULT_OK, new Intent().setData(Uri.parse("content://missing/orphan.mp4")));
        assertTrue(events.stream().noneMatch(event -> event.method.equals("nativeDrop")));
        coordinator.attach(activity);
        Reply second = call("pickMedia"); coordinator.dispose();
        assertEquals("MEDIA_PICKER_CLOSED", second.error); assertEquals(1, second.calls);
    }

    @Test public void launchFailureClearsRequestForRetry() {
        activity.failLaunch = true;
        Reply first = call("pickMedia");
        assertEquals("DOCK_UNAVAILABLE", first.error); assertEquals(1, first.calls);
        activity.failLaunch = false;
        Reply next = call("pickMedia"); assertEquals(0, next.calls);
        coordinator.onActivityResult(DockCoordinator.PICK_SEND_MEDIA, Activity.RESULT_CANCELED, null);
        assertNull(next.error); assertEquals(1, next.calls);
    }

    private Map<?, ?> awaitDrop() throws Exception {
        long deadline = System.currentTimeMillis() + 5000;
        while (System.currentTimeMillis() < deadline) {
            Shadows.shadowOf(Looper.getMainLooper()).idle();
            for (MethodCall event : events) if (event.method.equals("nativeDrop")) return (Map<?, ?>) event.arguments;
            Thread.sleep(10);
        }
        throw new AssertionError("Media import did not complete");
    }

    private static final class Reply { int calls; Object value; String error; }

    public static class PickerActivity extends Activity {
        boolean changing, failLaunch;
        @Override public boolean isChangingConfigurations() { return changing; }
        @Override public void startActivityForResult(Intent intent, int requestCode) {
            if (failLaunch) throw new ActivityNotFoundException("fixture launch unavailable");
            super.startActivityForResult(intent, requestCode);
        }
    }
}
