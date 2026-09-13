package org.paranoid.text;

import android.content.*;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import android.system.*;
import java.io.*;

/** Only one verified cache APK. Android enforces the nonexported temporary URI read grant. */
public final class UpdateProvider extends ContentProvider {
    @Override public boolean onCreate(){return true;}
    private File checked(Uri uri,String mode)throws FileNotFoundException {
        try{return UpdatePolicy.providerFile(getContext().getCacheDir(),uri.toString(),mode);}
        catch(Exception e){throw new FileNotFoundException("Verified update unavailable");}
    }
    @Override public ParcelFileDescriptor openFile(Uri uri,String mode)throws FileNotFoundException {
        File apk=checked(uri,mode);FileDescriptor fd=null;
        try {
            fd=Os.open(apk.getAbsolutePath(),OsConstants.O_RDONLY|OsConstants.O_NOFOLLOW|OsConstants.O_CLOEXEC,0);
            StructStat st=Os.fstat(fd);
            if(!OsConstants.S_ISREG(st.st_mode) || st.st_uid!=android.os.Process.myUid() || st.st_nlink!=1
                || (st.st_mode&077)!=0 || st.st_size<1)throw new IOException("private APK required");
            return ParcelFileDescriptor.dup(fd);
        }catch(Exception e){throw new FileNotFoundException("Verified update unavailable");}
        finally{if(fd!=null)try{Os.close(fd);}catch(Exception ignored){}}
    }
    @Override public String getType(Uri uri){if(!UpdatePolicy.URI.equals(uri.toString()))throw new IllegalArgumentException("Unknown update URI");return "application/vnd.android.package-archive";}
    @Override public Cursor query(Uri uri,String[] projection,String selection,String[] args,String sort){
        if(selection!=null || args!=null || sort!=null)throw new IllegalArgumentException("No update query selectors");
        File apk;try{apk=checked(uri,"r");}catch(FileNotFoundException e){throw new IllegalArgumentException("Update unavailable");}
        String[] columns=projection==null?new String[]{OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE}:projection;
        Object[] values=new Object[columns.length];
        for(int i=0;i<columns.length;i++){
            if(OpenableColumns.DISPLAY_NAME.equals(columns[i]))values[i]="ParanoID-update.apk";
            else if(OpenableColumns.SIZE.equals(columns[i]))values[i]=apk.length();
            else throw new IllegalArgumentException("Unknown update column");
        }
        MatrixCursor cursor=new MatrixCursor(columns,1);cursor.addRow(values);return cursor;
    }
    @Override public Uri insert(Uri uri,ContentValues values){throw new UnsupportedOperationException("Read only");}
    @Override public int delete(Uri uri,String selection,String[] args){throw new UnsupportedOperationException("Read only");}
    @Override public int update(Uri uri,ContentValues values,String selection,String[] args){throw new UnsupportedOperationException("Read only");}
}
