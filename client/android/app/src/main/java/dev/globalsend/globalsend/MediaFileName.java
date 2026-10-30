package dev.globalsend.globalsend;

import android.webkit.MimeTypeMap;

/** Some gallery providers use a numeric DISPLAY_NAME even for JPEG/MP4 files. */
final class MediaFileName {
    static boolean needsSuffix(String name) {
        if(name==null || name.isEmpty())return false;
        int dot=name.lastIndexOf('.');return dot<=0 || dot==name.length()-1;
    }
    static String withType(String name,String mime) {
        if(!needsSuffix(name) || mime==null)return name;
        String type=mime.split(";",2)[0].trim().toLowerCase(java.util.Locale.ROOT);
        if(!type.startsWith("image/") && !type.startsWith("video/"))return name;
        String extension="image/jpeg".equals(type)?"jpg":MimeTypeMap.getSingleton().getExtensionFromMimeType(type);
        if(extension==null)return name;
        return (name.endsWith(".")?name.substring(0,name.length()-1):name)+"."+extension;
    }
}
