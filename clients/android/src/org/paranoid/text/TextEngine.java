package org.paranoid.text;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.system.Os;
import android.system.OsConstants;
import android.util.AtomicFile;
import org.json.JSONArray;
import org.json.JSONObject;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.net.ssl.HttpsURLConnection;
import java.io.*;
import java.net.URL;
import java.nio.charset.StandardCharsets;
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
    private String state="", realm="", token="", tlsPin="";
    private boolean broken=false, hasSnapshot=false;
    private SecretKey storageKey;
    private TextEngine(Context context) {
        directory=context.getFilesDir();file=new AtomicFile(new File(directory,"text-state.enc"));
        worker.execute(()->{
            try {
                hasSnapshot=file.getBaseFile().exists() || new File(file.getBaseFile()+".bak").exists();
                if(hasSnapshot) {
                    if(Math.max(file.getBaseFile().length(),new File(file.getBaseFile()+".bak").length())>9L*1024*1024)throw new IOException("snapshot limit");
                    JSONObject saved=new JSONObject(SnapshotCodec.open(key(),file.readFully()));
                    realm=checkedUrl(saved.getString("realm"));token=checkedToken(saved.getString("token"));
                    tlsPin=PinnedTls.checkedPin(saved.getString("tls_pin"));
                    state=saved.getJSONObject("state").toString();
                    JSONObject view=invoke(state,new JSONObject().put("op","view"));
                    if(!view.getJSONObject("public").getString("realm").equals(realm))throw new IOException("realm mismatch");
                }
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
    public void configure(String url,String credential,String device,String suppliedPin) {submit(()->{
        String nextRealm=checkedUrl(url);String nextToken=credential.isEmpty()?token:checkedToken(credential);
        String nextPin=PinnedTls.checkedPin(suppliedPin);
        checkedToken(nextToken);
        String next=state;
        if(state.isEmpty())next=invoke("",new JSONObject().put("op","init").put("device",device).put("realm",nextRealm)).getJSONObject("state").toString();
        else {
            JSONObject pub=invoke(state,new JSONObject().put("op","view")).getJSONObject("public");
            if(!realm.equals(nextRealm) || !tlsPin.equals(nextPin) || !pub.getString("device").equals(device))throw new IOException("identity change refused");
        }
        persist(nextRealm,nextToken,nextPin,next);realm=nextRealm;token=nextToken;tlsPin=nextPin;state=next;
    });}
    public void pair(String code) {submit(()->{
        apply(new JSONObject().put("op","pair").put("peer",new JSONObject(code)).put("verified",true));
        publish("Код собеседника закреплён");pump();
    });}
    public void send(String text,Queued completion) {
        worker.execute(()->{
            boolean committed=false;
            try {
                if(broken)throw new IOException("local state unavailable");
                apply(new JSONObject().put("op","send").put("text",text));committed=true;
                ui.post(()->completion.done(true));publish("Сообщение сохранено в очередь");pump();publish("Синхронизация завершена");
            } catch(Throwable error) {publish("Отправка не завершена; сохранённая очередь не удалена.");}
            finally {if(!committed)ui.post(()->completion.done(false));}
        });
    }
    public void sync() {
        if(!syncScheduled.compareAndSet(false,true))return;
        worker.execute(()->{
            try {if(!broken)pump();publish("Синхронизация завершена");}
            catch(Throwable error){publish("Нет синхронизации. Проверьте HTTPS, доступ и код собеседника; данные сохранены.");}
            finally{syncScheduled.set(false);}
        });
    }
    private JSONObject invoke(String previous,JSONObject request) throws Exception {
        String raw=CoreBridge.command(previous,request.toString());
        if(raw==null)throw new IOException("native failure");
        JSONObject response=new JSONObject(raw);
        if(response.has("error"))throw new IOException("core rejected operation");
        return response;
    }
    private void apply(JSONObject request) throws Exception {
        String next=invoke(state,request).getJSONObject("state").toString();
        // Only promote memory state after a verified durable local write. On any
        // ambiguous storage failure freeze, rather than reuse an old ratchet.
        persist(realm,token,tlsPin,next);state=next;
    }
    private SecretKey key() throws Exception {
        if(storageKey!=null)return storageKey;
        KeyStore keys=KeyStore.getInstance("AndroidKeyStore");keys.load(null);
        String alias="paranoid-text-state-v0";
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
    private void persist(String url,String credential,String pin,String next) throws Exception {
        FileOutputStream stream=null;
        try {
            JSONObject saved=new JSONObject().put("realm",url).put("token",credential).put("tls_pin",pin).put("state",new JSONObject(next));
            byte[] encrypted=SnapshotCodec.seal(key(),saved.toString());
            stream=file.startWrite();stream.write(encrypted);stream.getFD().sync();file.finishWrite(stream);stream=null;
            if(!Arrays.equals(file.readFully(),encrypted))throw new IOException("commit verification failed");
            FileDescriptor parent=Os.open(directory.getAbsolutePath(),OsConstants.O_RDONLY,0);
            try {if(!OsConstants.S_ISDIR(Os.fstat(parent).st_mode))throw new IOException("not a directory");Os.fsync(parent);}finally{Os.close(parent);}
            hasSnapshot=true;
        } catch(Throwable error) {broken=true;throw new IOException("local commit failed",error);}
        finally {if(stream!=null)file.failWrite(stream);}
    }
    private static String checkedToken(String s) throws IOException {
        if(!s.matches("[0-9a-f]{64}"))throw new IOException("invalid credential");return s;
    }
    private static String checkedUrl(String raw) throws Exception {
        String s=raw.trim();while(s.endsWith("/"))s=s.substring(0,s.length()-1);
        URL url=new URL(s);
        if(!url.getProtocol().equals("https") || url.getHost().isEmpty() || url.getUserInfo()!=null || url.getQuery()!=null || url.getRef()!=null || s.length()>512)throw new IOException("HTTPS origin required");
        return s;
    }
    private JSONObject http(String method,String path,JSONObject body) throws Exception {
        HttpsURLConnection connection=(HttpsURLConnection)new URL(realm+path).openConnection();
        connection.setSSLSocketFactory(PinnedTls.factory(new URL(realm).getHost(),tlsPin));
        // Platform hostname verification stays enabled; this factory also checks SAN.
        connection.setInstanceFollowRedirects(false);connection.setConnectTimeout(8000);connection.setReadTimeout(8000);
        connection.setRequestMethod(method);connection.setRequestProperty("Authorization","Bearer "+token);
        connection.setRequestProperty("Accept","application/json");
        try {
            if(body!=null) {
                byte[] bytes=body.toString().getBytes(StandardCharsets.UTF_8);
                connection.setDoOutput(true);connection.setRequestProperty("Content-Type","application/json");connection.setFixedLengthStreamingMode(bytes.length);
                try(OutputStream output=connection.getOutputStream()){output.write(bytes);}
            }
            int responseCode=connection.getResponseCode();
            if(responseCode!=200)throw new SyncCycle.Rejected(responseCode);
            ByteArrayOutputStream bytes=new ByteArrayOutputStream();
            try(InputStream input=connection.getInputStream()) {
                byte[] buffer=new byte[4096];int n;
                while((n=input.read(buffer))!=-1){if(bytes.size()+n>2*1024*1024)throw new IOException("response limit");bytes.write(buffer,0,n);}
            }
            return new JSONObject(new String(bytes.toByteArray(),StandardCharsets.UTF_8));
        } finally {connection.disconnect();}
    }
    private void flush() throws Exception {
        JSONArray outbox=invoke(state,new JSONObject().put("op","view")).getJSONArray("outbox");
        java.util.List<JSONObject> snapshot=new java.util.ArrayList<>();
        for(int i=0;i<outbox.length();i++)snapshot.add(outbox.getJSONObject(i));
        SyncCycle.drain(snapshot,envelope->{
            JSONObject accepted=http("POST","/v0/messages",envelope);
            if(!accepted.getString("id").equals(envelope.getString("id")) || accepted.getLong("sequence")<1)throw new IOException("invalid acceptance");
            apply(new JSONObject().put("op","accepted").put("id",envelope.getString("id")));
        },()->broken);
    }
    private void pump() throws Exception {
        if(state.isEmpty() || new JSONObject(state).isNull("peer"))return;
        SyncCycle.run(this::flush,this::receivePage,()->broken);
    }
    private void receivePage() throws Exception {
        long cursor=invoke(state,new JSONObject().put("op","view")).getLong("cursor");
        JSONArray messages=http("GET","/v0/messages?after="+cursor+"&limit=20",null).getJSONArray("messages");
        if(messages.length()>20)throw new IOException("page limit");
        for(int i=0;i<messages.length();i++)apply(new JSONObject().put("op","receive").put("message",messages.getJSONObject(i)));
    }
    private void publish(String status) {
        JSONObject display=new JSONObject();
        try {
            display.put("broken",broken).put("configured",!state.isEmpty()).put("realm",realm).put("tls_pin",tlsPin);
            if(!broken && !state.isEmpty()) {
                JSONObject view=invoke(state,new JSONObject().put("op","view"));
                // Private snapshots, tokens and content keys never enter the UI view.
                display.put("public",view.getJSONObject("public")).put("messages",view.getJSONArray("messages"));
                display.put("paired",!new JSONObject(state).isNull("peer"));
                display.put("rejected_count",view.optLong("rejected_count",0));
            }
        } catch(Throwable error){broken=true;try{display.put("broken",true);}catch(Exception ignored){}}
        JSONObject safeView=display;
        long rejected=display.optLong("rejected_count",0);
        String visibleStatus=status+(rejected>0?" ⚠ Не принято событий: "+rejected+". История на сервере не удалена; доставка этих событий не подтверждена.":"");
        ui.post(()->{Listener target=listener;if(target!=null)target.changed(safeView,visibleStatus);});
    }
}
