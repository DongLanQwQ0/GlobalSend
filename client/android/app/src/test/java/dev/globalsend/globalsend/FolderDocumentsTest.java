package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.Manifest;
import android.app.Activity;
import android.content.pm.ProviderInfo;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.provider.DocumentsProvider;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;
import java.io.*;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.util.*;
import org.junit.*;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowContentResolver;

/** Real SAF operations against an isolated, hierarchical DocumentsProvider. */
@RunWith(RobolectricTestRunner.class)
@Config(sdk=28, manifest=Config.NONE, shadows=ReceiveDirectoryTest.ModernDocumentQueries.class)
public class FolderDocumentsTest {
    Activity activity; Tree provider; ReceiveDirectory receiver;
    final Uri selected = DocumentsContract.buildTreeDocumentUri("folder-fixtures", "root");
    final BinaryMessenger messenger = new BinaryMessenger() {
        public void send(String c, ByteBuffer m) {}
        public void send(String c, ByteBuffer m, BinaryReply r) {}
        public void setMessageHandler(String c, BinaryMessageHandler h) {}
    };
    @Before public void setup() throws Exception {
        activity=Robolectric.buildActivity(Activity.class).setup().get();
        provider=new Tree(); provider.disk=new File(activity.getCacheDir(), "hierarchical-provider"); provider.disk.mkdirs();
        ProviderInfo info=new ProviderInfo(); info.authority="folder-fixtures"; info.exported=true; info.grantUriPermissions=true;
        info.readPermission=Manifest.permission.MANAGE_DOCUMENTS; info.writePermission=Manifest.permission.MANAGE_DOCUMENTS;
        provider.attachInfo(activity, info); ShadowContentResolver.registerProviderInternal(info.authority, provider);
        receiver=new ReceiveDirectory(activity, new MethodChannel(messenger,"folder-test"), (fd,writable)->provider.lastOpened.file.getPath());
    }
    @After public void close() { receiver.dispose(); activity.finish(); }
    @Test public void enumerateOriginalUrisAndEmptyDirectoriesWithoutOpeningPayloads() throws Exception {
        String source=provider.add("root", "资料", true);
        String nested=provider.add(source, "子目录", true);
        String file=provider.add(nested, "正文.txt", false);
        Files.write(provider.entries.get(file).file.toPath(), new byte[]{1,2,3});
        provider.add(source, "空目录", true);
        List<Map<String,Object>> entries=SendFolderEntries.read(activity, provider.uri(source));
        assertEquals(4, entries.size()); assertEquals(0,provider.opens);
        assertEquals("资料", entries.get(0).get("relativePath"));
        assertEquals("directory", entries.get(0).get("entryKind"));
        assertTrue(entries.stream().anyMatch(e->"资料/空目录".equals(e.get("relativePath"))));
        Map<String,Object> payload=entries.stream().filter(e->"资料/子目录/正文.txt".equals(e.get("relativePath"))).findFirst().get();
        assertEquals(provider.uri(file).toString(), payload.get("location"));
        assertArrayEquals(new byte[]{1,2,3}, Files.readAllBytes(provider.entries.get(file).file.toPath()));
    }
    @Test public void createNestedReceiveRenameResumeAndDeleteKeepActualParents() throws Exception {
        provider.add("root","资料",true);
        String root=receiver.directory(selected.toString(),"资料",true);
        assertEquals("资料 (1)",receiver.stat(root).get("name"));
        String nested=receiver.directory(root,"子目录",false);
        assertEquals(nested,receiver.directory(root,"子目录",false));
        String empty=receiver.directory(root,"空目录",false);
        Map<String,Object> handle=receiver.create(nested,"正文.txt.part");
        String location=(String)handle.get("location");
        String id=DocumentsContract.getDocumentId(Uri.parse(location));
        assertEquals(DocumentsContract.getDocumentId(Uri.parse(nested)),provider.entries.get(id).parent);
        try(RandomAccessFile output=new RandomAccessFile((String)handle.get("ioPath"),"rw")) {output.write(new byte[]{1,2});}
        receiver.close((String)handle.get("handle"),null);
        Map<String,Object> resumed=receiver.open(location,true);
        assertEquals(2L,((Number)resumed.get("size")).longValue());
        try(RandomAccessFile output=new RandomAccessFile((String)resumed.get("ioPath"),"rw")) {output.seek(2);output.write(3);}
        receiver.close((String)resumed.get("handle"),null);
        Map<String,Object> renamed=receiver.rename(location,"正文.txt");
        assertEquals("正文.txt",renamed.get("name"));
        assertEquals(DocumentsContract.getDocumentId(Uri.parse(nested)),provider.entries.get(id).parent);
        assertFalse(receiver.delete(root));
        assertTrue(receiver.delete((String)renamed.get("location")));
        assertTrue(receiver.delete(nested)); assertTrue(receiver.delete(empty)); assertTrue(receiver.delete(root));
        assertEquals(1,provider.entries.size());
    }
    static class Entry {
        String id,parent,name; boolean directory; File file;
        Entry(String id,String parent,String name,boolean directory,File file) {this.id=id;this.parent=parent;this.name=name;this.directory=directory;this.file=file;}
    }
    public static class Tree extends DocumentsProvider {
        File disk; Entry lastOpened; int opens;
        Map<String,Entry> entries=new LinkedHashMap<>();
        Uri uri(String id) {return DocumentsContract.buildDocumentUriUsingTree(DocumentsContract.buildTreeDocumentUri("folder-fixtures","root"),id);}
        String add(String parent,String name,boolean directory) throws IOException {
            String id=UUID.randomUUID().toString(); File file=new File(disk,id);
            if(directory)file.mkdir(); else file.createNewFile();
            entries.put(id,new Entry(id,parent,name,directory,file)); return id;
        }
        public boolean onCreate(){return true;}
        public Cursor queryRoots(String[] projection){return new MatrixCursor(new String[]{DocumentsContract.Root.COLUMN_ROOT_ID});}
        MatrixCursor cursor(String[] projection) {return new MatrixCursor(projection==null?new String[]{"document_id","_display_name","_size","mime_type","flags"}:projection);}
        void row(MatrixCursor cursor,String id) {
            Entry e=entries.get(id); Map<String,Object> data=new HashMap<>();
            data.put("document_id",id); data.put("_display_name",e==null?"接收目录":e.name);
            data.put("_size",e==null||e.directory?0L:e.file.length());
            data.put("mime_type",e==null||e.directory?DocumentsContract.Document.MIME_TYPE_DIR:"text/plain");
            data.put("flags",DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE|DocumentsContract.Document.FLAG_SUPPORTS_DELETE|DocumentsContract.Document.FLAG_SUPPORTS_RENAME|DocumentsContract.Document.FLAG_SUPPORTS_WRITE);
            Object[] values=new Object[cursor.getColumnCount()];String[] columns=cursor.getColumnNames();
            for(int i=0;i<columns.length;i++)values[i]=data.get(columns[i]);cursor.addRow(values);
        }
        public Cursor queryDocument(String id,String[] projection){MatrixCursor c=cursor(projection);if(id.equals("root")||entries.containsKey(id))row(c,id);return c;}
        public Cursor queryChildDocuments(String id,String[] projection,String sort){MatrixCursor c=cursor(projection);for(Entry e:entries.values())if(e.parent.equals(id))row(c,e.id);return c;}
        public boolean isChildDocument(String parent,String id){while(entries.containsKey(id)){id=entries.get(id).parent;if(parent.equals(id))return true;}return false;}
        public String createDocument(String parent,String mime,String name)throws FileNotFoundException {
            try{return add(parent,name,DocumentsContract.Document.MIME_TYPE_DIR.equals(mime));}catch(IOException e){throw new FileNotFoundException(e.toString());}
        }
        public String renameDocument(String id,String name)throws FileNotFoundException {Entry e=entries.get(id);if(e==null)throw new FileNotFoundException();e.name=name;return id;}
        public void deleteDocument(String id)throws FileNotFoundException {Entry e=entries.get(id);if(e==null||entries.values().stream().anyMatch(c->c.parent.equals(id))||!e.file.delete())throw new FileNotFoundException();entries.remove(id);}
        public ParcelFileDescriptor openDocument(String id,String mode,CancellationSignal signal)throws FileNotFoundException {lastOpened=entries.get(id);opens++;if(lastOpened==null||lastOpened.directory)throw new FileNotFoundException();return ParcelFileDescriptor.open(lastOpened.file,ParcelFileDescriptor.parseMode(mode));}
    }
}
