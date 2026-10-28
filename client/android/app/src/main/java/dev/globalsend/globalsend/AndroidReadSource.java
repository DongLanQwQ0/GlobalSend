package dev.globalsend.globalsend;

import android.content.Context;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.system.Os;
import java.io.Closeable;
import java.io.IOException;
import java.io.RandomAccessFile;

/** Random access to the original granted document, without reopening /proc/fd. */
final class AndroidReadSource implements Closeable {
    private final RandomAccessFile file;
    private final ParcelFileDescriptor descriptor;
    private long offset;

    AndroidReadSource(Context context, String path) throws Exception {
        path = ReceiveDirectory.readableLocation(context, path);
        if (path.startsWith("content://")) {
            file = null;
            descriptor = context.getContentResolver().openFileDescriptor(Uri.parse(path), "r");
            if (descriptor == null) throw new IOException("无法读取已授权的文件");
        } else {
            descriptor = null;
            file = new RandomAccessFile(path, "r");
        }
    }
    static java.io.InputStream openStream(Context context, String path) throws IOException {
        String location = ReceiveDirectory.readableLocation(context, path);
        if (!location.startsWith("content://")) return new java.io.FileInputStream(location);
        java.io.InputStream stream = context.getContentResolver().openInputStream(Uri.parse(location));
        if (stream == null) throw new IOException("无法读取已授权的文件");
        return stream;
    }
    long length() throws Exception { return file != null ? file.length() : descriptor.getStatSize(); }
    void seek(long position) throws Exception {
        if (position < 0) throw new IllegalArgumentException("Invalid offset");
        offset = position;
        if (file != null) file.seek(position);
    }
    int read(byte[] bytes, int start, int count) throws Exception {
        int read = file != null ? file.read(bytes, start, count)
            : Os.pread(descriptor.getFileDescriptor(), bytes, start, count, offset);
        if (read > 0) offset += read;
        return read == 0 && count > 0 ? -1 : read;
    }
    @Override public void close() throws IOException {
        if (file != null) file.close();
        if (descriptor != null) descriptor.close();
    }
}
