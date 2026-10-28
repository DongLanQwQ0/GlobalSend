package dev.globalsend.globalsend;

import android.content.Context;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.io.FileInputStream;
import java.io.ByteArrayOutputStream;
import org.json.JSONObject;

/** Reads the same installation preference as Flutter, including headless reception. */
final class ReceiveAppearance {
    final int surface, field, ink, muted, accent, soft;
    ReceiveAppearance(String mode, String color) {
        boolean dark = "dark".equals(mode), neutral = "neutral".equals(mode);
        surface = dark ? 0xff202124 : neutral ? 0xfff7f7f8 : 0xffffffff;
        ink = dark ? 0xffe9eaed : 0xff25272b;
        muted = dark ? 0xffabb0b8 : 0xff62666d;
        String[] names = {"green", "blue", "purple", "rose", "amber", "slate"};
        int[] colors = dark ? new int[]{0xff81d6b4,0xff9ecaff,0xffc9b6ff,0xfff3aec0,0xffeac17c,0xffb7c9d8}
            : new int[]{0xff176b50,0xff245ea8,0xff7051a8,0xffa34363,0xff815c17,0xff4c6375};
        int index = 0;
        for (int i=0; i<names.length; i++) if (names[i].equals(color)) index=i;
        accent = colors[index];
        field = neutral ? 0xffefeff1 : tint(accent, surface, dark ? .055f : .03f);
        float opacity = dark ? .13f : .08f;
        soft = tint(accent, surface, opacity);
    }
    private static int tint(int accent, int surface, float opacity) {
        int mixed=0xff000000;
        for (int shift : new int[]{0,8,16}) mixed |= Math.round(((accent>>shift)&255)*opacity + ((surface>>shift)&255)*(1-opacity)) << shift;
        return mixed;
    }
    static ReceiveAppearance load(Context context) {
        // path_provider_android's application-support path is Context.filesDir.
        File file = new File(context.getFilesDir(), "appearance.json");
        try (FileInputStream input = new FileInputStream(file); ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
            byte[] chunk = new byte[256]; int count;
            while ((count=input.read(chunk)) != -1) bytes.write(chunk,0,count);
            JSONObject value = new JSONObject(bytes.toString(StandardCharsets.UTF_8.name()));
            return new ReceiveAppearance(value.optString("mode"), value.optString("accent"));
        } catch (java.io.IOException | org.json.JSONException unavailable) {
            return new ReceiveAppearance("light", "green");
        }
    }
}
