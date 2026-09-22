package org.paranoid.devnet;
import android.content.Context;
import android.security.keystore.*;
import android.system.*;
import android.util.AtomicFile;
import org.json.JSONObject;
import org.paranoid.text.SnapshotCodec;
import java.io.*;
import java.security.KeyStore;
import javax.crypto.*;

/** Single application-owner executor only. A durable nonsecret intent marker
 * makes interrupted mutations fail closed across process restart; never rekey/reset.
 */
final class DevnetStore implements RegistrationFlow.Store {
    private static final String ALIAS="paranoid.devnet.seed.v1";
    private final Context context;
    private final AtomicFile file;
    private final File pending;
    private boolean frozen;
    DevnetStore(Context c){context=c.getApplicationContext();file=new AtomicFile(new File(context.getNoBackupFilesDir(),"devnet-state.enc"));pending=new File(context.getNoBackupFilesDir(),"devnet-write.pending");}
    private void syncDirectory()throws Exception {
        FileDescriptor dir=Os.open(context.getNoBackupFilesDir().getAbsolutePath(),OsConstants.O_RDONLY,0);
        try{Os.fsync(dir);}finally{Os.close(dir);}
    }
    private void markWrite()throws Exception {
        if(!pending.createNewFile())throw new IOException("storage_frozen");
        try(FileOutputStream out=new FileOutputStream(pending)){out.write(1);out.getFD().sync();}
        syncDirectory();
    }
    private KeyStore keys()throws Exception{KeyStore k=KeyStore.getInstance("AndroidKeyStore");k.load(null);return k;}
    public synchronized JSONObject load()throws Exception {
        if(frozen||pending.exists()){frozen=true;throw new IOException("storage_frozen");}
        KeyStore k=keys();boolean exists=file.getBaseFile().exists()||new File(file.getBaseFile()+".bak").exists()||new File(file.getBaseFile()+".new").exists();
        if(k.containsAlias(ALIAS)!=exists){frozen=true;throw new IOException("incomplete_retained_state");}
        if(!exists)return null;
        try {
            if(file.getBaseFile().length()>65536||new File(file.getBaseFile()+".bak").length()>65536)throw new IOException("state_limit");
            byte[] bytes=file.readFully();if(bytes.length>65536)throw new IOException("state_limit");
            JSONObject state=new JSONObject(SnapshotCodec.open((SecretKey)k.getKey(ALIAS,null),bytes));
            if(!DevnetRpc.GENESIS.equals(state.getString("genesis"))||!DevnetRpc.PROGRAM.equals(state.getString("program")))throw new IOException("state_domain");
            return state;
        }catch(Exception failure){frozen=true;throw new IOException("storage_frozen",failure);}
    }
    public synchronized void save(JSONObject state)throws Exception {
        if(frozen||pending.exists()){frozen=true;throw new IOException("storage_frozen");}
        String plaintext=state.toString();if(plaintext.length()>16000)throw new IOException("state_limit");
        FileOutputStream output=null;
        try {
            markWrite();
            KeyStore k=keys();
            if(!k.containsAlias(ALIAS)) {
                if(file.getBaseFile().exists()||new File(file.getBaseFile()+".bak").exists()||new File(file.getBaseFile()+".new").exists())throw new IOException("missing_key");
                KeyGenerator g=KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore");
                g.init(new KeyGenParameterSpec.Builder(ALIAS,KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build());g.generateKey();k=keys();
            }
            SecretKey key=(SecretKey)k.getKey(ALIAS,null);
            byte[] sealed=SnapshotCodec.seal(key,plaintext);
            output=file.startWrite();output.write(sealed);output.getFD().sync();file.finishWrite(output);output=null;
            syncDirectory();
            String check=SnapshotCodec.open(key,file.readFully());if(!plaintext.equals(check))throw new IOException("state_readback");
            if(!pending.delete())throw new IOException("storage_frozen");
            syncDirectory();
        }catch(Exception failure){
            // Never delete/regenerate a wrapping key or committed file as recovery.
            // Do not open AtomicFile after failure: it may restore backups/remove partial files.
            // Re-latch if final marker deletion succeeded but its directory sync failed.
            if(!pending.exists())try{markWrite();}catch(Exception cannotPersist){/* I/O failure: keep this process frozen; never send. */}
            if(output!=null)try{output.close();}catch(IOException ignored){}
            frozen=true;throw new IOException("storage_frozen",failure);
        }
    }
}
