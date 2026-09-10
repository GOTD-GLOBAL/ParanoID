import org.paranoid.text.*;
import org.json.*;
import javax.crypto.spec.SecretKeySpec;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.SecureRandom;
import java.util.*;
import java.util.concurrent.*;

/** Synthetic real JNI/TLS peer; external aiortc implements the actual media port. */
public final class VoicePeerBridge implements AutoCloseable {
    private final ExecutorService owner=Executors.newSingleThreadExecutor();
    private final ScheduledExecutorService calls=Executors.newSingleThreadScheduledExecutor();
    private final Map<String,CallController.Completion> accepted=new HashMap<>();
    private final ArrayDeque<JSONObject> media=new ArrayDeque<>();
    private final SelfServiceClient client;
    private final RealtimeLoop loop;
    private final CallController controller;
    private volatile boolean connected;
    private static JSONObject copy(JSONObject value){return new JSONObject(value.toString());}
    VoicePeerBridge(Path root,String realm,String pin)throws Exception {
        Files.createDirectories(root);
        Path keyFile=root.resolve("fixture.key"),snapshot=root.resolve("fixture.enc");
        StorageGuard.requireContinuity(Files.exists(snapshot),Files.exists(keyFile));
        byte[] keyBytes;
        if(Files.exists(keyFile))keyBytes=Files.readAllBytes(keyFile);
        else{keyBytes=new byte[32];new SecureRandom().nextBytes(keyBytes);Files.write(keyFile,keyBytes,StandardOpenOption.CREATE_NEW);}
        SecretKeySpec key=new SecretKeySpec(keyBytes,"AES");
        String saved=Files.exists(snapshot)?SnapshotCodec.open(key,Files.readAllBytes(snapshot)):null;
        client=new SelfServiceClient(saved,next->{
            byte[] ciphertext=SnapshotCodec.seal(key,next);Path temporary=root.resolve("fixture.next");
            try(FileOutputStream out=new FileOutputStream(temporary.toFile())){out.write(ciphertext);out.getFD().sync();}
            Files.move(temporary,snapshot,StandardCopyOption.REPLACE_EXISTING,StandardCopyOption.ATOMIC_MOVE);
            if(!Arrays.equals(ciphertext,Files.readAllBytes(snapshot)))throw new IOException("fixture commit verification");
        },realm,pin);
        controller=calls.submit(()->new CallController(new CallController.Clock(){
            public long wallMillis(){return System.currentTimeMillis();}
            public long monotonicMillis(){return TimeUnit.NANOSECONDS.toMillis(System.nanoTime());}
        },new CallController.Port(){
            public void send(String account,JSONObject body,CallController.Completion completion){
                JSONObject immutable=copy(body);
                owner.execute(()->{try{
                    if(!connected||accepted.size()>=16)throw new IOException("fixture call unavailable");
                    String id=client.sendCall(account,immutable);accepted.put(id,completion);loop.kick();
                }catch(Exception failure){calls.execute(()->completion.done(false));}});
            }
            private void event(String operation,long generation,String sdp){
                if(media.size()>=32){controllerFailure();return;}
                media.add(new JSONObject().put("operation",operation).put("generation",generation).put("sdp",sdp));
            }
            private void authorize(String operation,long generation,String sdp){
                loop.requestVoiceRelay((config,success)->calls.execute(()->{
                    boolean usable=success&&(config==null||config.usable(System.currentTimeMillis(),System.nanoTime()));
                    if(!controller.mediaAuthorized(generation,usable))return;
                    if(media.size()>=32){controllerFailure();return;}
                    JSONObject command=new JSONObject().put("operation",operation).put("generation",generation).put("sdp",sdp);
                    // Private fixture IPC only; the driver removes this before public views/logs.
                    if(config!=null)command.put("relay",new JSONObject().put("urls",new JSONArray(config.urls()))
                        .put("username",config.username()).put("credential",config.password()));
                    media.add(command);
                }));
            }
            public void mediaOffer(long generation){authorize("offer",generation,"");}
            public void mediaAnswer(long generation,String sdp){authorize("answer_offer",generation,sdp);}
            public void mediaRemoteAnswer(long generation,String sdp){event("set_answer",generation,sdp);}
            public void mediaMute(boolean value){media.add(new JSONObject().put("operation","mute").put("value",value));}
            public void mediaSpeaker(boolean value){media.add(new JSONObject().put("operation","speaker").put("value",value));}
            public void mediaClose(){loop.cancelVoiceRelay();media.add(new JSONObject().put("operation","close"));}
            public void changed(JSONObject view){}
        })).get(5,TimeUnit.SECONDS);
        client.setCallListener(event->{JSONObject immutable=copy(event);calls.execute(()->controller.received(immutable));});
        client.setAcceptedListener(id->{CallController.Completion completion=accepted.remove(id);if(completion!=null)calls.execute(()->completion.done(true));});
        loop=new RealtimeLoop(owner,client,new RealtimeLoop.Listener(){
            public void changed(boolean online,String status){connected=online;calls.execute(()->controller.connection(online));}
            public void authorizationLost(){calls.execute(()->controller.authorizationLost());}
        });
        calls.scheduleAtFixedRate(()->controller.tick(),1,1,TimeUnit.SECONDS);
    }
    private void controllerFailure(){calls.execute(()->controller.authorizationLost());}
    JSONObject command(JSONObject request)throws Exception {
        String op=request.getString("operation");
        if(op.equals("create")){owner.submit(()->{client.createIdentity();return null;}).get(10,TimeUnit.SECONDS);loop.start();}
        else if(op.equals("resume")){loop.start();}
        else if(op.equals("pair")){owner.submit(()->{client.pair(request.getString("contact"),true);return null;}).get(10,TimeUnit.SECONDS);}
        else if(op.equals("text")){owner.submit(()->{client.send(request.getString("account"),request.getString("text"));return null;}).get(10,TimeUnit.SECONDS);loop.kick();}
        else if(!op.equals("view"))calls.submit(()->{
            switch(op){
                case "start":controller.start(request.getString("account"),true);break;
                case "answer":controller.answer(true);break;
                case "reject":controller.reject();break;
                case "hangup":controller.hangup();break;
                case "mute":controller.mute(request.getBoolean("value"));break;
                case "speaker":controller.speaker(request.getBoolean("value"));break;
                case "local_description":controller.localDescription(request.getLong("generation"),request.getString("sdp"),request.getString("fingerprint"),request.getString("ice_ufrag"),request.getString("ice_pwd"));break;
                case "media_state":controller.mediaState(request.getLong("generation"),request.getString("state"));break;
                default:throw new IllegalArgumentException("unknown fixture command");
            }
            return null;
        }).get(10,TimeUnit.SECONDS);
        JSONObject view=owner.submit(()->client.publicView().put("connected",connected)).get(10,TimeUnit.SECONDS);
        return calls.submit(()->{JSONArray events=new JSONArray();while(!media.isEmpty())events.put(media.remove());return view.put("call",controller.snapshot()).put("media_commands",events);}).get(10,TimeUnit.SECONDS);
    }
    public void close(){try{calls.submit(()->controller.hangup()).get(3,TimeUnit.SECONDS);}catch(Exception ignored){}loop.close();calls.shutdownNow();owner.shutdownNow();}
    public static void main(String[] args)throws Exception {
        try(VoicePeerBridge peer=new VoicePeerBridge(Paths.get(args[0]),args[1],args[2])){
            BufferedReader reader=new BufferedReader(new InputStreamReader(System.in,StandardCharsets.UTF_8));String line;
            while((line=reader.readLine())!=null){JSONObject reply;
                try{if(line.length()>65536)throw new IOException("fixture input limit");reply=peer.command(new JSONObject(line));}
                catch(Exception failure){reply=new JSONObject().put("error",failure.getClass().getSimpleName());}
                System.out.println(reply);System.out.flush();
            }
        }
    }
}
