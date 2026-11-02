package dev.globalsend.globalsend;

import android.database.Cursor;
import android.database.MatrixCursor;
import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract.Document;
import android.provider.DocumentsProvider;
import java.io.FileNotFoundException;

/** A real document tree preserves child names and empty directories; no ZIP. */
public final class RemoteReferenceProvider extends DocumentsProvider {
    private static final String[] COLUMNS={Document.COLUMN_DOCUMENT_ID,Document.COLUMN_DISPLAY_NAME,Document.COLUMN_MIME_TYPE,Document.COLUMN_SIZE,Document.COLUMN_FLAGS};
    public boolean onCreate(){return true;}
    public Cursor queryRoots(String[] projection){return new MatrixCursor(projection==null?new String[]{"root_id"}:projection);}
    public Cursor queryDocument(String id,String[] projection) throws FileNotFoundException {
        RemoteReferenceFiles.Entry entry=RemoteReferenceFiles.entry(id);grantTreeAccess(entry);MatrixCursor result=new MatrixCursor(projection==null?COLUMNS:projection);add(result,id,entry.part(RemoteReferenceFiles.relative(id)));return result;
    }
    public Cursor queryChildDocuments(String id,String[] projection,String sortOrder) throws FileNotFoundException {
        RemoteReferenceFiles.Entry entry=RemoteReferenceFiles.entry(id);grantTreeAccess(entry);String parent=RemoteReferenceFiles.relative(id)+"/";MatrixCursor result=new MatrixCursor(projection==null?COLUMNS:projection);
        for(RemoteReferenceFiles.Part part:entry.parts)if(part.path.startsWith(parent) && part.path.indexOf('/',parent.length())<0)add(result,entry.token+":"+part.path,part);return result;
    }
    public boolean isChildDocument(String parentId,String childId){try{return RemoteReferenceFiles.entry(parentId)==RemoteReferenceFiles.entry(childId) && RemoteReferenceFiles.relative(childId).startsWith(RemoteReferenceFiles.relative(parentId)+"/");}catch(FileNotFoundException missing){return false;}}
    private void grantTreeAccess(RemoteReferenceFiles.Entry entry) {
        if(getContext()==null || !entry.parts.get(0).directory)return;
        String caller=getCallingPackage();
        if(caller==null || caller.equals(getContext().getPackageName()))return;
        grantTreeAccess(getContext(),entry,caller);
    }
    static void grantTreeAccess(android.content.Context context,RemoteReferenceFiles.Entry entry,String caller) {
        synchronized(entry) {
        if(entry.revoked || !entry.parts.get(0).directory || entry.grantedPackages.contains(caller))return;
        // The framework already checked this caller's drag grant for the root
        // document. Child IDs are distinct URI path segments, so extend that
        // same explicit folder drop to its registered tree, not another root.
        android.net.Uri tree=android.provider.DocumentsContract.buildTreeDocumentUri(
            context.getPackageName()+".remote-files",entry.token+":"+entry.parts.get(0).path);
        long identity=android.os.Binder.clearCallingIdentity();
        try {
            context.grantUriPermission(caller,tree,android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION|android.content.Intent.FLAG_GRANT_PREFIX_URI_PERMISSION);
            entry.grantContext=context.getApplicationContext();entry.grantedTree=tree;entry.grantedPackages.add(caller);
        }
        finally {android.os.Binder.restoreCallingIdentity(identity);}
        }
    }
    public ParcelFileDescriptor openDocument(String id,String mode,CancellationSignal cancellation) throws FileNotFoundException {
        if(!"r".equals(mode))throw new FileNotFoundException("只读文件");if(cancellation!=null)cancellation.throwIfCanceled();
        RemoteReferenceFiles.Entry entry=RemoteReferenceFiles.entry(id);return RemoteReferenceFiles.open(getContext(),entry,entry.part(RemoteReferenceFiles.relative(id)));
    }
    private static void add(MatrixCursor cursor,String id,RemoteReferenceFiles.Part part){MatrixCursor.RowBuilder row=cursor.newRow();
        for(String column:cursor.getColumnNames())switch(column){
            case Document.COLUMN_DOCUMENT_ID:row.add(column,id);break;
            case Document.COLUMN_DISPLAY_NAME:row.add(column,part.name);break;
            case Document.COLUMN_SIZE:row.add(column,part.size);break;
            case Document.COLUMN_FLAGS:row.add(column,0);break;
            case Document.COLUMN_MIME_TYPE:row.add(column,part.directory?Document.MIME_TYPE_DIR:DockShareProvider.mimeType(part.name));break;
        }
    }
}
