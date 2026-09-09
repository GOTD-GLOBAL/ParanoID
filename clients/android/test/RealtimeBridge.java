import org.paranoid.text.*;
import org.json.*;
import javax.crypto.spec.SecretKeySpec;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.SecureRandom;
import java.util.*;
import java.util.concurrent.*;

/** Actual JNI/network fixture. Every mutable client action and notification has one owner. */
public final class RealtimeBridge {
    private static Path root;
    private static String realm,pin;
    private static final Map<String,Peer> peers=new LinkedHashMap<>();
    private static final class Peer {
        final String name;
        final ExecutorService owner;
        final JSONObject seen=new JSONObject();
        SelfServiceClient client;
        RealtimeLoop loop;
        volatile Throwable failure;
        volatile boolean connected;
        boolean failCommit;
        int notifications;
        String lastSaved;
        SecretKeySpec key;
        Peer(String name)throws Exception {
            this.name=name;owner=Executors.newSingleThreadExecutor(r->new Thread(r,"owner-"+name));
            owner.submit(()->{try{open();}catch(Exception e){throw new CompletionException(e);}}).get(10,TimeUnit.SECONDS);
            loop=new RealtimeLoop(owner,client,(online,status)->{
                try {
                    requireOwner();connected=online;if(client.broken()){connected=false;notifications++;return;}JSONObject publicView=client.publicView();long notification=System.nanoTime();
                    if(lastSaved!=null){
                        String disk=SnapshotCodec.open(key,Files.readAllBytes(root.resolve(name+".enc")));
                        if(!disk.equals(lastSaved))throw new AssertionError("notification preceded durable snapshot");
                        JSONObject actual=new JSONObject(CoreBridge.command(new JSONObject(disk).getJSONObject("state").toString(),"{\"op\":\"view\"}"));
                        if(!actual.optJSONArray("dialogs").toString().equals(publicView.optJSONArray("dialogs").toString()))throw new AssertionError("published dialogs differ from encrypted durable snapshot");
                    }
                    JSONArray dialogs=publicView.optJSONArray("dialogs");
                    if(dialogs!=null)for(int i=0;i<dialogs.length();i++){
                        JSONObject dialog=dialogs.getJSONObject(i);JSONArray messages=dialog.getJSONArray("messages");
                        for(int j=0;j<messages.length();j++){
                            JSONObject message=messages.getJSONObject(j);String text=message.getString("text");
                            if(!message.getString("author").equals(dialog.getString("own"))&&!seen.has(text))seen.put(text,notification);
                        }
                    }
                    notifications++;
                }catch(Throwable error){failure=error;}
            });
        }
        private void requireOwner(){if(!Thread.currentThread().getName().equals("owner-"+name))throw new AssertionError("state operation or listener escaped owner");}
        private void open()throws Exception {
            requireOwner();Path keyPath=root.resolve(name+".key"),snapshot=root.resolve(name+".enc");
            StorageGuard.requireContinuity(Files.exists(snapshot),Files.exists(keyPath));
            byte[] bytes;
            if(Files.exists(keyPath))bytes=Files.readAllBytes(keyPath);
            else{bytes=new byte[32];new SecureRandom().nextBytes(bytes);Files.write(keyPath,bytes,StandardOpenOption.CREATE_NEW);}
            key=new SecretKeySpec(bytes,"AES");lastSaved=Files.exists(snapshot)?SnapshotCodec.open(key,Files.readAllBytes(snapshot)):null;
            client=new SelfServiceClient(lastSaved,saved->{
                requireOwner();
                if(failCommit){failCommit=false;throw new IOException("synthetic fixture persistence fault");}
                byte[] encrypted=SnapshotCodec.seal(key,saved);Path next=root.resolve(name+".next");
                try(FileOutputStream stream=new FileOutputStream(next.toFile())){stream.write(encrypted);stream.getFD().sync();}
                Files.move(next,snapshot,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);
                if(!Arrays.equals(encrypted,Files.readAllBytes(snapshot)))throw new IOException("synthetic fixture readback failure");
                lastSaved=saved;
            },realm,pin);
        }
        JSONObject command(String operation,String value,long commandStart)throws Exception{
            if(operation.equals("start")){loop.start();return view();}
            if(operation.equals("stop")){loop.stop();return view();}
            if(operation.equals("kick")){loop.kick();return view();}
            if(operation.equals("close")){loop.close();return view();}
            return owner.submit(()->{
                requireOwner();if(failure!=null)throw new AssertionError("listener invariant failed",failure);
                switch(operation){
                    case "create":client.createIdentity();break;
                    case "pair":client.previewContact(value);client.pair(value,true);break;
                    case "send":JSONObject send=new JSONObject(value);client.send(send.getString("account"),send.getString("text"));break;
                    case "pending":break;
                    case "fail_next_commit":failCommit=true;break;
                    case "view":break;
                    default:throw new IOException("unknown fixture operation");
                }
                JSONObject result=checkedView();result.put("command_start_ns",commandStart).put("owner_completed_ns",System.nanoTime());
                if(operation.equals("pending"))result.put("pending",client.pending());
                return result;
            }).get(3,TimeUnit.SECONDS);
        }
        private JSONObject checkedView()throws Exception {
            requireOwner();if(failure!=null)throw new AssertionError("listener invariant failed",failure);
            if(client.broken())return new JSONObject().put("broken",true).put("notifications",notifications).put("seen",new JSONObject(seen.toString()));
            return client.publicView().put("seen",new JSONObject(seen.toString())).put("connected",connected).put("notifications",notifications);
        }
        JSONObject view()throws Exception{return owner.submit(()->checkedView()).get(3,TimeUnit.SECONDS);}
        void shutdown(){try{loop.close();}catch(Exception ignored){}owner.shutdown();try{if(!owner.awaitTermination(5,TimeUnit.SECONDS))owner.shutdownNow();}catch(InterruptedException e){Thread.currentThread().interrupt();}}
    }
    public static void main(String[] args)throws Exception {
        root=Paths.get(args[0]);Files.createDirectories(root);realm=args[1];pin=args[2];
        BufferedReader input=new BufferedReader(new InputStreamReader(System.in,StandardCharsets.UTF_8));String line;
        try{while((line=input.readLine())!=null){JSONObject result;
            try{
                long started=System.nanoTime();String[] parts=line.split("\t",-1);if(parts.length!=3||!parts[0].matches("one|two|three|four"))throw new IOException("synthetic peer required");
                Peer peer=peers.get(parts[0]);if(peer==null){peer=new Peer(parts[0]);peers.put(parts[0],peer);}
                String value=new String(Base64.getDecoder().decode(parts[2]),StandardCharsets.UTF_8);
                result=peer.command(parts[1],value,started);
            }catch(Throwable error){Throwable cause=error instanceof ExecutionException?error.getCause():error;result=new JSONObject().put("error",cause.getClass().getSimpleName()).put("detail",String.valueOf(cause.getMessage()));}
            System.out.println(Base64.getEncoder().encodeToString(result.toString().getBytes(StandardCharsets.UTF_8)));System.out.flush();
        }}finally{for(Peer peer:peers.values())peer.shutdown();}
    }
}
