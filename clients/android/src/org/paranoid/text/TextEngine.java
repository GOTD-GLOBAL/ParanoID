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

/** One state owner for ratchets/commits; RealtimeLoop owns separate network lanes. */
public final class TextEngine {
    public interface Listener { void changed(JSONObject publicView, String status); }
    public interface Queued { void done(boolean committed); }
    public interface CallListener {void changed(JSONObject call);}
    private static TextEngine instance;
    public static synchronized TextEngine get(Context context) {
        if(instance==null)instance=new TextEngine(context.getApplicationContext());
        return instance;
    }
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private final Handler ui=new Handler(Looper.getMainLooper());
    private final AtomicFile file;
    private final File directory;
    private final Context context;
    private volatile Listener listener;
    private CallListener callListener;
    private final CallController calls;
    private WebRtcAudioEngine media;
    private volatile boolean callActive,callDraining;
    private int mediaClosing;
    private Runnable pendingMedia;
    private long drainGeneration;
    private final java.util.Map<String,CallController.Completion> callCompletions=new java.util.HashMap<>();
    private String lastCallState="idle";
    private SelfServiceClient client;
    private RealtimeLoop realtime;
    private boolean connected=false,backgroundEnabled=false;
    private long lastIncoming=-1;
    private boolean broken=false, hasSnapshot=false, unsupportedSnapshot=false;
    private SecretKey storageKey;
    private TextEngine(Context context) {
        this.context=context;
        calls=new CallController(new CallController.Clock(){
            public long wallMillis(){return System.currentTimeMillis();}
            public long monotonicMillis(){return android.os.SystemClock.elapsedRealtime();}
        },new CallController.Port(){
            public void send(String account,JSONObject body,CallController.Completion completion){
                final JSONObject immutable;
                try{immutable=new JSONObject(body.toString());}catch(Exception failure){completion.done(false);return;}
                worker.execute(()->{try{
                    if(broken||client==null||!connected||callCompletions.size()>=16)throw new IOException("call unavailable");
                    String id=client.sendCall(account,immutable);callCompletions.put(id,completion);startConnection();realtime.kick();
                }catch(Exception failure){ui.post(()->completion.done(false));}});
            }
            public void mediaOffer(long generation){openMedia(generation,null);}
            public void mediaAnswer(long generation,String sdp){openMedia(generation,sdp);}
            public void mediaRemoteAnswer(long generation,String sdp){if(media!=null&&calls.snapshot().optLong("generation")==generation)media.setAnswer(sdp);}
            public void mediaMute(boolean value){if(media!=null)media.setMuted(value);}
            public void mediaSpeaker(boolean value){if(media!=null)media.setSpeaker(value);}
            public void mediaClose(){
                pendingMedia=null;WebRtcAudioEngine owned=media;media=null;
                if(owned!=null){mediaClosing++;owned.close(()->{mediaClosing--;Runnable next=pendingMedia;pendingMedia=null;if(next!=null)next.run();});}
                VoiceCallService.stop(context);
                callDraining=true;worker.execute(()->callCompletions.clear());
                long drain=++drainGeneration;
                ui.postDelayed(()->{if(drain!=drainGeneration)return;callDraining=false;worker.execute(()->{if(!callActive&&listener==null&&!backgroundEnabled&&realtime!=null){stopConnection();}});},10000);
            }
            public void changed(JSONObject view){
                String state=view.optString("state");callActive=!state.equals("idle")&&!state.equals("ended");
                if(state.equals("incoming")&&!lastCallState.equals(state)&&listener==null)VoiceCallService.incoming(context);
                if(!state.equals("incoming"))VoiceCallService.clearIncoming(context);lastCallState=state;
                if(callListener!=null)callListener.changed(view);
                worker.execute(()->{if(callActive||callDraining)startConnection();else if(listener==null&&!backgroundEnabled&&realtime!=null){stopConnection();}});
            }
        });
        ui.post(new Runnable(){public void run(){calls.tick();ui.postDelayed(this,1000);}});
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
                client=new SelfServiceClient(saved,this::persist);
                client.setCallListener(event->{JSONObject immutable=new JSONObject(event.toString());ui.post(()->calls.received(immutable));});
                client.setAcceptedListener(id->{CallController.Completion completion=callCompletions.remove(id);if(completion!=null)ui.post(()->completion.done(true));});
                realtime=new RealtimeLoop(worker,client,new RealtimeLoop.Listener(){
                    public void changed(boolean online,String status){connected=online;ui.post(()->calls.connection(online));publish(status);}
                    public void authorizationLost(){ui.post(()->calls.authorizationLost());}
                });
                publish("Готово. Только тестовые сообщения.");
            } catch(Throwable error) {broken=true;unsupportedSnapshot=error instanceof SelfServiceClient.UnsupportedSnapshot;publish("Не удалось открыть локальное состояние. Данные сохранены; ключи не сбрасываются.");}
        });
    }
    /** The call controller, UI and SDK callbacks share Android's main thread. */
    public CallController calls(){return calls;}
    public void listenCalls(CallListener next){callListener=next;next.changed(calls.snapshot());}
    public void unlistenCalls(CallListener current){if(callListener==current)callListener=null;}
    private void openMedia(long generation,String offer){
        if(!calls.active()||calls.snapshot().optLong("generation")!=generation)return;
        if(mediaClosing>0){pendingMedia=()->openMedia(generation,offer);return;}
        if(context.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO)!=android.content.pm.PackageManager.PERMISSION_GRANTED){calls.authorizationLost();return;}
        if(media!=null){calls.mediaState(generation,"failed");return;}
        try{
            media=new WebRtcAudioEngine(context,new WebRtcAudioEngine.Listener(){
                public void onLocalDescription(String type,String sdp){
                    String fingerprint="",ufrag="",password="";
                    for(String line:sdp.split("\\r?\\n")){
                        if(line.startsWith("a=fingerprint:sha-256 "))fingerprint=line.substring(22).replace(":","").toLowerCase(java.util.Locale.ROOT);
                        if(line.startsWith("a=ice-ufrag:"))ufrag=line.substring(12);
                        if(line.startsWith("a=ice-pwd:"))password=line.substring(10);
                    }
                    calls.localDescription(generation,sdp,fingerprint,ufrag,password);
                }
                public void onConnected(){calls.mediaState(generation,"connected");}
                public void onDisconnected(){calls.mediaState(generation,"disconnected");}
                public void onError(String reason){calls.mediaState(generation,"failed");}
            });
            // Creation may have waited for an older engine's asynchronous close.
            // Apply this generation's current intent before capture can start.
            JSONObject desired=calls.snapshot();
            media.setMuted(desired.optBoolean("muted"));media.setSpeaker(desired.optBoolean("speaker"));
            if(offer==null)media.createOffer();else media.createAnswer(offer);
        }catch(RuntimeException failure){calls.mediaState(generation,"failed");}
    }
    public void listen(Listener next) {listener=next;worker.execute(()->{publish(broken?"Локальные данные недоступны; сброс не выполнен":"Подключаемся…");startConnection();});}
    public void unlisten(Listener current) {if(listener==current){listener=null;worker.execute(()->{if(!backgroundEnabled&&!callActive&&!callDraining&&realtime!=null){stopConnection();}});}}
    private void stopConnection(){if(realtime!=null)realtime.stop();connected=false;ui.post(()->calls.connection(false));}
    private void startConnection(){if(!broken&&realtime!=null&&(listener!=null||backgroundEnabled||callActive||callDraining)){realtime.start();realtime.kick();}}
    public void background(boolean enabled){worker.execute(()->{backgroundEnabled=enabled;if(enabled)startConnection();else if(listener==null&&!callActive&&!callDraining&&realtime!=null){stopConnection();}publish(enabled?"Фоновое подключение включено":"Фоновое подключение выключено");});}
    private interface Task {void run() throws Exception;}
    private void submit(Task task) {
        worker.execute(()->{try {
            if(broken)throw new IOException("local state unavailable");
            task.run();publish(connected?"Подключено":"Подключаемся…");startConnection();
        } catch(Throwable error) {publish(broken ? "Ошибка локального хранения. Операции остановлены; данные не удалены." : userError(error));}});
    }
    public interface UpdateTrust {void ready(String[] trust);}
    /** Read only on the state owner; update I/O runs on a separate worker. */
    public void updateTrust(UpdateTrust callback){worker.execute(()->{
        String[] trust=null;
        try{if(!broken && hasSnapshot && client!=null)trust=client.updateTrust();}catch(Exception ignored){}
        String[] result=trust;ui.post(()->callback.ready(result));
    });}
    public void createIdentity(){submit(()->client.createIdentity());}
    public void pair(String code){submit(()->client.pair(code,true));}
    public void block(String account,boolean blocked){if(blocked)calls.block(account);submit(()->client.block(account,blocked));}
    public interface Preview {void checked(JSONObject preview);}
    public void previewContact(String code,Preview callback){submit(()->{
        JSONObject preview=client.previewContact(code);ui.post(()->callback.checked(preview));
    });}
    public void send(String account,String text,Queued completion) {
        worker.execute(()->{
            boolean committed=false;
            try {
                if(broken)throw new IOException("local state unavailable");
                client.send(account,text);committed=true;
                ui.post(()->completion.done(true));publish("Сообщение сохранено в очередь");startConnection();
            } catch(Throwable error) {publish("Отправка не завершена; сохранённая очередь не удалена.");}
            finally {if(!committed)ui.post(()->completion.done(false));}
        });
    }
    public void sync() {
        worker.execute(this::startConnection);
    }

    private String userError(Throwable error) {
        if(error instanceof SyncCycle.Rejected) {
            int code=((SyncCycle.Rejected)error).status;
            if(code==404)return "Сервер пока не поддерживает эту версию. Ваш ID, контакты и очередь сохранены.";
            if(code==429)return "Сервер занят. Подключение повторится автоматически; ID сохранён.";
            if(code==507)return "Хранилище сервера заполнено. Очередь и история сохранены.";
            if(code==401||code==409)return "Не удалось подтвердить подключение. Ваши ключи и данные сохранены; новый ID не создаётся.";
        }
        return "Подключение или проверка контакта не завершены. Повторим подключение автоматически. ID, очередь и история сохранены.";
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
        } catch(Throwable error) {broken=true;ui.post(()->calls.authorizationLost());throw new IOException("local commit failed",error);}
        finally {if(stream!=null)file.failWrite(stream);}
    }

    private void publish(String status) {
        JSONObject display=new JSONObject();
        try {
            if(client!=null && client.broken())broken=true;
            if(!broken && client!=null)display=client.publicView();
            display.put("broken",broken).put("unsupported_snapshot",unsupportedSnapshot).put("connected",connected&&!broken).put("background_enabled",backgroundEnabled);
        } catch(Throwable error){broken=true;try{display.put("broken",true);}catch(Exception ignored){}}
        JSONObject safeView=display;
        long incoming=0;
        org.json.JSONArray dialogs=display.optJSONArray("dialogs");
        if(dialogs!=null)for(int n=0;n<dialogs.length();n++) {
            JSONObject dialog=dialogs.optJSONObject(n);if(dialog==null)continue;
            org.json.JSONArray messages=dialog.optJSONArray("messages");if(messages==null)continue;
            for(int m=0;m<messages.length();m++){JSONObject message=messages.optJSONObject(m);if(message!=null&&!message.optString("author").equals(dialog.optString("own")))incoming++;}
        }
        if(lastIncoming>=0&&incoming>lastIncoming&&backgroundEnabled&&listener==null&&!broken)BackgroundConnectionService.incoming(context);
        lastIncoming=incoming;
        long rejected=display.optLong("rejected_count",0);
        String visibleStatus=status+(rejected>0?" ⚠ Не принято событий: "+rejected+". История на сервере не удалена; доставка этих событий не подтверждена.":"");
        ui.post(()->{Listener target=listener;if(target!=null)target.changed(safeView,visibleStatus);});
    }
}
