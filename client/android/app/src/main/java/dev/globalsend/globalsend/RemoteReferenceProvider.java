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
        RemoteReferenceFiles.Entry entry=RemoteReferenceFiles.entry(id);MatrixCursor result=new MatrixCursor(projection==null?COLUMNS:projection);add(result,id,entry.part(RemoteReferenceFiles.relative(id)));return result;
    }
    public Cursor queryChildDocuments(String id,String[] projection,String sortOrder) throws FileNotFoundException {
        RemoteReferenceFiles.Entry entry=RemoteReferenceFiles.entry(id);String parent=RemoteReferenceFiles.relative(id)+"/";MatrixCursor result=new MatrixCursor(projection==null?COLUMNS:projection);
        for(RemoteReferenceFiles.Part part:entry.parts)if(part.path.startsWith(parent) && part.path.indexOf('/',parent.length())<0)add(result,entry.token+":"+part.path,part);return result;
    }
    public boolean isChildDocument(String parentId,String childId){try{return RemoteReferenceFiles.entry(parentId)==RemoteReferenceFiles.entry(childId) && RemoteReferenceFiles.relative(childId).startsWith(RemoteReferenceFiles.relative(parentId)+"/");}catch(FileNotFoundException missing){return false;}}
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
