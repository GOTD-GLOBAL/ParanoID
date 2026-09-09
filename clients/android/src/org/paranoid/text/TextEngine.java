package org.paranoid.text;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.system.Os;
import android.system.OsConstants;
import android.util.AtomicFile;

import org.json.JSONObject;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;

import java.io.*;

import java.security.KeyStore;
import java.util.Arrays;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** One process-wide worker owns ratchets, local commits and network sequencing. */
public final class TextEngine {
    public interface Listener { void changed(JSONObject publicView, String status); }
    public interface Queued { void done(boolean committed); }
    private static TextEngine instance;
    public static synchronized TextEngine get(Context context) {
        if(instance==null)instance=new TextEngine(context.getApplicationContext());
        return instance;
    }
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private final Handler ui=new Handler(Looper.getMainLooper());
    private final AtomicFile file;
    private final File directory;
    private volatile Listener listener;
    private final java.util.concurrent.atomic.AtomicBoolean syncScheduled=new java.util.concurrent.atomic.AtomicBoolean();
    private KeyClient client;
    private boolean broken=false, hasSnapshot=false;
    private SecretKey storageKey;
    private TextEngine(Context context) {
        directory=context.getFilesDir();file=new AtomicFile(new File(directory,"text-state.enc"));
        worker.execute(()->{
            try {
                hasSnapshot=file.getBaseFile().exists() || new File(file.getBaseFile()+".bak").exists();
                KeyStore retained=KeyStore.getInstance("AndroidKeyStore");retained.load(null);
                StorageGuard.requireContinuity(hasSnapshot,retained.containsAlias(StorageGuard.ALIAS));
                String saved=null;
                if(hasSnapshot) {
                    if(Math.max(file.getBaseFile().length(),new File(file.getBaseFile()+".bak").length())>9L*1024*1024)throw new IOException("snapshot limit");
                    saved=SnapshotCodec.open(key(),file.readFully());
                }
                client=new KeyClient(saved,this::persist);
                publish("Готово. Только тестовые сообщения.");
            } catch(Throwable error) {broken=true;publish("Не удалось открыть локальное состояние. Данные сохранены; ключи не сбрасываются.");}
        });
    }
    public void listen(Listener next) {listener=next;worker.execute(()->publish(broken?"Локальные данные недоступны; сброс не выполнен":"Готово"));}
    public void unlisten(Listener current) {if(listener==current)listener=null;}
    private interface Task {void run() throws Exception;}
    private void submit(Task task) {
        worker.execute(()->{try {
            if(broken)throw new IOException("local state unavailable");
            task.run();publish("Синхронизация завершена");
        } catch(Throwable error) {publish(broken ? "Ошибка локального хранения. Операции остановлены; данные не удалены." : "Операция не завершена. Проверьте код, HTTPS и доступ; очередь и история сохранены.");}});
    }
    public void createIdentity(){submit(()->client.createIdentity());}
    public void importGrant(String code){submit(()->{client.importGrant(code);client.sync();});}
    public void pair(String code){submit(()->{client.pair(code,true);client.sync();});}
    public interface Preview {void checked(JSONObject preview);}
    public void previewContact(String code,Preview callback){submit(()->{
        JSONObject preview=client.previewContact(code);ui.post(()->callback.checked(preview));
    });}
    public void send(String text,Queued completion) {
        worker.execute(()->{
            boolean committed=false;
            try {
                if(broken)throw new IOException("local state unavailable");
                client.send(text);committed=true;
                ui.post(()->completion.done(true));publish("Сообщение сохранено в очередь");client.sync();publish("Синхронизация завершена");
            } catch(Throwable error) {publish("Отправка не завершена; сохранённая очередь не удалена.");}
            finally {if(!committed)ui.post(()->completion.done(false));}
        });
    }
    public void sync() {
        if(!syncScheduled.compareAndSet(false,true))return;
        worker.execute(()->{
            try {if(!broken && client!=null)client.sync();publish("Синхронизация завершена");}
            catch(Throwable error){publish("Нет синхронизации. Проверьте HTTPS, доступ и код собеседника; данные сохранены.");}
            finally{syncScheduled.set(false);}
        });
    }

    private SecretKey key() throws Exception {
        if(storageKey!=null)return storageKey;
        KeyStore keys=KeyStore.getInstance("AndroidKeyStore");keys.load(null);
        String alias=StorageGuard.ALIAS; // unchanged paranoid-text-state-v0 identity
        if(keys.containsAlias(alias))storageKey=(SecretKey)keys.getKey(alias,null);
        else {
            if(hasSnapshot)throw new IOException("key missing; do not regenerate");
            KeyGenerator generator=KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder(alias,KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build());
            storageKey=generator.generateKey();
        }
        if(storageKey==null)throw new IOException("key unavailable");
        return storageKey;
    }
    private void persist(String saved) throws Exception {
        FileOutputStream stream=null;
        try {
            byte[] encrypted=SnapshotCodec.seal(key(),saved);
            stream=file.startWrite();stream.write(encrypted);stream.getFD().sync();file.finishWrite(stream);stream=null;
            if(!Arrays.equals(file.readFully(),encrypted))throw new IOException("commit verification failed");
            FileDescriptor parent=Os.open(directory.getAbsolutePath(),OsConstants.O_RDONLY,0);
            try {if(!OsConstants.S_ISDIR(Os.fstat(parent).st_mode))throw new IOException("not a directory");Os.fsync(parent);}finally{Os.close(parent);}
            hasSnapshot=true;
        } catch(Throwable error) {broken=true;throw new IOException("local commit failed",error);}
        finally {if(stream!=null)file.failWrite(stream);}
    }

    private void publish(String status) {
        JSONObject display=new JSONObject();
        try {
            if(client!=null && client.broken())broken=true;
            if(!broken && client!=null)display=client.publicView();
            display.put("broken",broken);
        } catch(Throwable error){broken=true;try{display.put("broken",true);}catch(Exception ignored){}}
        JSONObject safeView=display;
        long rejected=display.optLong("rejected_count",0);
        String visibleStatus=status+(rejected>0?" ⚠ Не принято событий: "+rejected+". История на сервере не удалена; доставка этих событий не подтверждена.":"");
        ui.post(()->{Listener target=listener;if(target!=null)target.changed(safeView,visibleStatus);});
    }
}
