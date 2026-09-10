import org.paranoid.text.*;
import org.json.JSONObject;
import com.sun.net.httpserver.HttpsServer;
import com.sun.net.httpserver.HttpsConfigurator;
import javax.net.ssl.*;
import java.net.*;
import java.io.*;
import java.lang.reflect.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.cert.X509Certificate;
import java.security.spec.X509EncodedKeySpec;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Real pinned HTTPS and JNI signing; enrollment/session and HTTP outcomes are synthetic.
 * No PostgreSQL issuer, media SDK, deployment, or physical-device claim is made here.
 */
public final class VoiceRelayLaneSmoke {
    static ExecutorService owner, handlers;
    static HttpsServer server;
    static RealtimeLoop loop;
    static SelfServiceClient client;
    static JSONObject session;
    static PublicKey authKey;
    static String realm,pin;
    static final AtomicInteger authority=new AtomicInteger(), attempts=new AtomicInteger(), polls=new AtomicInteger();
    static final AtomicReference<Throwable> serverFailure=new AtomicReference<>();
    static final Set<String> nonces=ConcurrentHashMap.newKeySet();
    static volatile String mode="relay";
    static volatile CountDownLatch ownerHeld, ownerRelease, responseHeld, responseRelease;
    static int checks;

    static void check(boolean value,String message) {if(!value)throw new AssertionError(message);}
    static Object field(Object target,String name)throws Exception {Field f=target.getClass().getDeclaredField(name);f.setAccessible(true);return f.get(target);}
    static void field(Object target,String name,Object value)throws Exception {Field f=target.getClass().getDeclaredField(name);f.setAccessible(true);f.set(target,value);}
    static void own() {check(Thread.currentThread().getName().equals("voice-lane-owner"),"client/callback escaped state owner");}
    static byte[] hex(String value) {byte[] bytes=new byte[value.length()/2];for(int i=0;i<bytes.length;i++)bytes[i]=(byte)Integer.parseInt(value.substring(i*2,i*2+2),16);return bytes;}
    static String digest(byte[] bytes)throws Exception {StringBuilder value=new StringBuilder();for(byte b:MessageDigest.getInstance("SHA-256").digest(bytes))value.append(String.format(Locale.ROOT,"%02x",b&255));return value.toString();}
    static byte[] transcript(String... fields)throws Exception {
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();DataOutputStream out=new DataOutputStream(bytes);
        for(String field:fields){byte[] value=field.getBytes(StandardCharsets.UTF_8);out.writeInt(value.length);out.write(value);}return bytes.toByteArray();
    }
    static void verify(String authorization,String method,String path)throws Exception {
        check(authorization!=null&&authorization.startsWith("ParanoidSessionV2 "),"missing native session authorization");
        String[] parts=authorization.substring("ParanoidSessionV2 ".length()).split("\\.");
        check(parts.length==3&&parts[0].equals(session.getString("id")),"wrong session binding");
        check(UUID.fromString(parts[1]).version()==4&&nonces.add(parts[1]),"nonce reused");
        Signature signature=Signature.getInstance("Ed25519");signature.initVerify(authKey);
        signature.update(transcript("paranoid-session-request-v1",parts[0],session.getString("epoch"),
            Long.toString(session.getLong("expires")),realm,pin,session.getString("account"),session.getString("device"),
            session.getString("credential"),parts[1],method,path,digest(new byte[0])));
        check(signature.verify(Base64.getDecoder().decode(parts[2])),"actual native signature does not bind HTTP operation");
    }
    static byte[] config()throws Exception {
        long expires=System.currentTimeMillis()/1000+1200;
        return new JSONObject().put("v",1).put("urls",new org.json.JSONArray()
                .put("turn:127.0.0.1:34781?transport=udp").put("turn:127.0.0.1:34781?transport=tcp"))
            .put("username",expires+":0123456789abcdef0123456789abcdef")
            .put("credential",Base64.getEncoder().encodeToString(new byte[20])).put("expires",expires).put("ttl",1200)
            .toString().getBytes(StandardCharsets.UTF_8);
    }
    static void start(String keyStore)throws Exception {
        owner=Executors.newSingleThreadExecutor(r->new Thread(r,"voice-lane-owner"));
        handlers=Executors.newFixedThreadPool(4);
        KeyStore store=KeyStore.getInstance("PKCS12");try(InputStream input=new FileInputStream(keyStore)){store.load(input,"test-only".toCharArray());}
        KeyManagerFactory keys=KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());keys.init(store,"test-only".toCharArray());
        SSLContext tls=SSLContext.getInstance("TLS");tls.init(keys.getKeyManagers(),null,null);
        pin=digest(((X509Certificate)store.getCertificate("tls")).getPublicKey().getEncoded());
        server=HttpsServer.create(new InetSocketAddress("127.0.0.1",0),0);server.setHttpsConfigurator(new HttpsConfigurator(tls));server.setExecutor(handlers);
        realm="https://127.0.0.1:"+server.getAddress().getPort();
        owner.submit(()->{own();client=new SelfServiceClient(null,saved->{own();},realm,pin);client.createIdentity();
            JSONObject c=client.publicView().getJSONObject("request").getJSONObject("credential");
            String credential=digest(transcript("paranoid-credential-v1",c.getString("root"),c.getString("account"),c.getString("device"),c.getString("auth"),realm,pin,c.getString("olm")));
            client.registrationResult(new JSONObject().put("mode","active").put("account",c.getString("account")).put("device",c.getString("device")).put("credential",credential));
            session=new JSONObject().put("id",UUID.randomUUID().toString()).put("epoch",UUID.randomUUID().toString()).put("expires",System.currentTimeMillis()/1000+300)
                .put("realm",realm).put("pin",pin).put("account",c.getString("account")).put("device",c.getString("device")).put("credential",credential);
            ByteArrayOutputStream encodedKey=new ByteArrayOutputStream();encodedKey.write(hex("302a300506032b6570032100"));encodedKey.write(Base64.getDecoder().decode(c.getString("auth")));
            authKey=KeyFactory.getInstance("Ed25519").generatePublic(new X509EncodedKeySpec(encodedKey.toByteArray()));
            return null;
        }).get(10,TimeUnit.SECONDS);
        server.createContext("/",exchange->{
            try {
                check(exchange.getRequestBody().read()==-1,"unexpected request body");
                String path=exchange.getRequestURI().toString();
                verify(exchange.getRequestHeaders().getFirst("Authorization"),exchange.getRequestMethod(),path);
                byte[] body;int status=200;
                if(path.equals("/v2/voice/turn")) {
                    int attempt=attempts.incrementAndGet();String selected=mode;
                    check(exchange.getRequestMethod().equals("GET"),"voice method changed");
                    if(selected.equals("stale401")&&attempt==2){
                        owner.execute(()->{own();ownerHeld.countDown();try{check(ownerRelease.await(10,TimeUnit.SECONDS),"owner gate timeout");}catch(InterruptedException e){Thread.currentThread().interrupt();}});
                        check(ownerHeld.await(3,TimeUnit.SECONDS),"owner not held before old failure");
                    }
                    if(selected.equals("held")) {responseHeld.countDown();check(responseRelease.await(8,TimeUnit.SECONDS),"response gate timeout");}
                    if(selected.equals("stale401")||selected.equals("401")||(selected.equals("retry")&&attempt==1))status=401;
                    else if(selected.equals("404"))status=404;
                    else if(selected.equals("429"))status=429;
                    else if(selected.equals("500"))status=500;
                    else if(selected.equals("302")){status=302;exchange.getResponseHeaders().set("Location",realm+"/forbidden");}
                    body=selected.equals("malformed")?"{\"v\":1}".getBytes(StandardCharsets.UTF_8):status==200?config():"{\"error\":\"synthetic_fault\"}".getBytes(StandardCharsets.UTF_8);
                } else {
                    check(path.equals("/v2/messages?after=0&limit=20")||path.equals("/v2/events?after=0&limit=20"),"unexpected endpoint or redirect");
                    polls.incrementAndGet();if(path.startsWith("/v2/events"))Thread.sleep(100);
                    body="{\"messages\":[]}".getBytes(StandardCharsets.UTF_8);
                }
                exchange.getResponseHeaders().set("Cache-Control","no-store");exchange.sendResponseHeaders(status,body.length);
                try(OutputStream output=exchange.getResponseBody()){output.write(body);}
            }catch(IOException cancelled){/* A cancelled owned HTTP exchange can close before response write. */}
            catch(Throwable failure){serverFailure.compareAndSet(null,failure);}
            finally{exchange.close();}
        });server.start();
        loop=new RealtimeLoop(owner,client,new RealtimeLoop.Listener(){
            public void changed(boolean online,String status){own();}
            public void authorizationLost(){own();authority.incrementAndGet();}
        });
        Class<?> type=Class.forName("org.paranoid.text.RealtimeLoop$Session");Constructor<?> ctor=type.getDeclaredConstructor(JSONObject.class);ctor.setAccessible(true);
        field(loop,"session",ctor.newInstance(session));field(loop,"realtime",true);field(loop,"discoveryNeeded",false);field(loop,"discoveryAt",System.nanoTime());
        loop.start();owner.submit(()->null).get(3,TimeUnit.SECONDS);
    }
    static CompletableFuture<String> request(){
        CompletableFuture<String> result=new CompletableFuture<>();
        loop.requestVoiceRelay((config,success)->{own();result.complete(success?(config==null?"direct":"relay"):"failed");});return result;
    }
    static void select(String value){mode=value;attempts.set(0);}
    static void scenario(String value,String expected,int expectedAttempts)throws Exception {
        select(value);Object retained=field(loop,"session");
        check(request().get(8,TimeUnit.SECONDS).equals(expected),"wrong relay response semantics: "+value);
        check(attempts.get()==expectedAttempts,"wrong retry count: "+value);
        check(field(loop,"session")==retained&&!(Boolean)field(loop,"discoveryNeeded"),"optional voice response invalidated text session: "+value);
        check(authority.get()==0,"voice failure escaped request scope: "+value);checks++;
    }
    static void staleFailure()throws Exception {
        select("stale401");ownerHeld=new CountDownLatch(1);ownerRelease=new CountDownLatch(1);
        CompletableFuture<String> stale=request();
        Object oldRequest=field(loop,"voiceRequest");Future<?> running=(Future<?>)field(oldRequest,"task");
        check(ownerHeld.await(5,TimeUnit.SECONDS),"second real HTTPS 401 did not hold owner");
        running.get(3,TimeUnit.SECONDS); // Both old notifications are now queued behind the held owner.
        check(attempts.get()==2,"old request did not use exactly two signed nonces");
        long generation=(Long)field(loop,"generation");loop.cancelVoiceRelay();select("relay");
        CompletableFuture<String> fresh=request();ownerRelease.countDown();
        check(fresh.get(8,TimeUnit.SECONDS).equals("relay"),"replacement request failed");
        check((Long)field(loop,"generation")==generation,"test accidentally restarted realtime generation");
        check(!stale.isDone(),"cancelled callback was delivered");
        check(authority.get()==0,"stale confirmed voice 401 escaped cancellation and fired global authorizationLost");checks++;
    }
    static void boundedReplacement()throws Exception {
        select("held");responseHeld=new CountDownLatch(1);responseRelease=new CountDownLatch(1);
        CompletableFuture<String> stale=request();check(responseHeld.await(5,TimeUnit.SECONDS),"voice response did not hold");
        int before=polls.get();owner.submit(()->{own();return client.publicView();}).get(2,TimeUnit.SECONDS);
        long deadline=System.nanoTime()+2000000000L;while(polls.get()<=before&&System.nanoTime()<deadline)Thread.sleep(10);
        check(polls.get()>before,"held voice response blocked signed text receive lane");
        List<CompletableFuture<String>> replaced=new ArrayList<>();loop.cancelVoiceRelay();
        for(int n=0;n<20;n++)replaced.add(request());
        ThreadPoolExecutor lane=(ThreadPoolExecutor)field(loop,"voiceNetwork");
        check(lane.getActiveCount()<=1&&lane.getQueue().size()<=1,"unbounded voice executor");
        mode="relay";responseRelease.countDown();
        check(replaced.get(19).get(8,TimeUnit.SECONDS).equals("relay"),"latest replacement not delivered");
        check(!stale.isDone(),"cancelled held reply delivered");
        for(int n=0;n<19;n++)check(!replaced.get(n).isDone(),"superseded queued callback delivered");checks++;
    }
    public static void main(String[] args)throws Exception {
        try {
            start(args[0]);staleFailure();
            scenario("404","direct",1);scenario("relay","relay",1);scenario("retry","relay",2);
            scenario("401","failed",2);scenario("429","failed",1);scenario("500","failed",1);
            scenario("302","failed",1);scenario("malformed","failed",1);boundedReplacement();
            if(serverFailure.get()!=null)throw new AssertionError("fixture HTTP/signature invariant failed",serverFailure.get());
            System.out.println("PASS "+checks+" real pinned HTTPS/JNI voice scenarios: stale 401 isolation, exact retries, optional 404, strict failure, bounded replacement, signed text progress");
        } finally {
            if(ownerRelease!=null)ownerRelease.countDown();if(responseRelease!=null)responseRelease.countDown();
            if(loop!=null)loop.close();if(server!=null)server.stop(0);if(handlers!=null)handlers.shutdownNow();if(owner!=null){owner.shutdownNow();owner.awaitTermination(5,TimeUnit.SECONDS);}
        }
    }
}
