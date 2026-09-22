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

/** Single application-owner executor only. Ambiguous writes freeze mutation until process exit.
 * This is not a persistent freeze latch; restart/storage lifecycle acceptance remains unrun.
 */
final class DevnetStore {
    private static final String ALIAS="paranoid.devnet.seed.v1";
    private final Context context;
    private final AtomicFile file;
    private boolean frozen;
    DevnetStore(Context c){context=c.getApplicationContext();file=new AtomicFile(new File(context.getNoBackupFilesDir(),"devnet-state.enc"));}
    private KeyStore keys()throws Exception{KeyStore k=KeyStore.getInstance("AndroidKeyStore");k.load(null);return k;}
    synchronized JSONObject load()throws Exception {
        if(frozen)throw new IOException("storage_frozen");
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
    synchronized void save(JSONObject state)throws Exception {
        if(frozen)throw new IOException("storage_frozen");
        String plaintext=state.toString();if(plaintext.length()>16000)throw new IOException("state_limit");
        FileOutputStream output=null;
        try {
            KeyStore k=keys();
            if(!k.containsAlias(ALIAS)) {
                if(file.getBaseFile().exists()||new File(file.getBaseFile()+".bak").exists()||new File(file.getBaseFile()+".new").exists())throw new IOException("missing_key");
                KeyGenerator g=KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore");
                g.init(new KeyGenParameterSpec.Builder(ALIAS,KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build());g.generateKey();k=keys();
            }
            SecretKey key=(SecretKey)k.getKey(ALIAS,null);
            byte[] sealed=SnapshotCodec.seal(key,plaintext);
            output=file.startWrite();output.write(sealed);output.getFD().sync();file.finishWrite(output);output=null;
            FileDescriptor dir=Os.open(context.getNoBackupFilesDir().getAbsolutePath(),OsConstants.O_RDONLY,0);
            try{Os.fsync(dir);}finally{Os.close(dir);}
            String check=SnapshotCodec.open(key,file.readFully());if(!plaintext.equals(check))throw new IOException("state_readback");
        }catch(Exception failure){
            // Never delete/regenerate a wrapping key or committed file as recovery.
            // Preserve even partial write evidence instead of restoring an older transaction ledger.
            if(output!=null)try{output.close();}catch(IOException ignored){}
            frozen=true;throw new IOException("storage_frozen",failure);
        }
    }
}
