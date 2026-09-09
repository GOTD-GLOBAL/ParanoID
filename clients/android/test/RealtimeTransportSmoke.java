import org.paranoid.text.*;
import org.json.JSONObject;
import com.sun.net.httpserver.HttpsServer;
import com.sun.net.httpserver.HttpsConfigurator;
import javax.net.ssl.*;
import java.net.*;
import java.io.*;
import java.security.*;
import java.security.cert.X509Certificate;
import java.util.*;
import java.util.concurrent.*;
import java.lang.reflect.*;

/** Real TLS transport behavior. Missing pool uses the retained adapter to capture behavior RED. */
public final class RealtimeTransportSmoke {
    static Object pool;
    static String realm,pin;
    static JSONObject call(String method,String path,String body,String auth)throws Exception {
        if(pool==null)return KeyTransport.call(realm,pin,method,path,body,auth);
        try{return (JSONObject)pool.getClass().getMethod("call",String.class,String.class,String.class,String.class).invoke(pool,method,path,body,auth);}
        catch(InvocationTargetException e){throw (Exception)e.getCause();}
    }
    public static void main(String[] args)throws Exception {
        KeyStore store=KeyStore.getInstance("PKCS12");try(InputStream in=new FileInputStream(args[0])){store.load(in,"test-only".toCharArray());}
        KeyManagerFactory km=KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());km.init(store,"test-only".toCharArray());
        SSLContext ssl=SSLContext.getInstance("TLS");ssl.init(km.getKeyManagers(),null,null);
        StringBuilder hex=new StringBuilder();for(byte b:MessageDigest.getInstance("SHA-256").digest(((X509Certificate)store.getCertificate("tls")).getPublicKey().getEncoded()))hex.append(String.format("%02x",b&255));pin=hex.toString();
        Set<Integer> ports=ConcurrentHashMap.newKeySet();CountDownLatch waiting=new CountDownLatch(1),release=new CountDownLatch(1);
        ExecutorService handlers=Executors.newCachedThreadPool(),workers=Executors.newFixedThreadPool(2);
        HttpsServer server=HttpsServer.create(new InetSocketAddress("127.0.0.1",0),0);server.setHttpsConfigurator(new HttpsConfigurator(ssl));server.setExecutor(handlers);
        server.createContext("/",e->{
            ports.add(e.getRemoteAddress().getPort());
            try {while(e.getRequestBody().read()!=-1){}
                if(e.getRequestURI().getPath().equals("/v2/events")){waiting.countDown();if(!release.await(5,TimeUnit.SECONDS))throw new IOException("fixture wait expired");}
                if(e.getRequestURI().getPath().equals("/v2/redirect")){e.getResponseHeaders().set("Location",realm+"/v2/forbidden");e.sendResponseHeaders(307,-1);return;}
                if(e.getRequestURI().getPath().equals("/v2/forbidden"))throw new AssertionError("redirect followed");
                byte[] bytes="{\"status\":\"ok\"}".getBytes("UTF-8");e.sendResponseHeaders(200,bytes.length);try(OutputStream out=e.getResponseBody()){out.write(bytes);}
            }catch(InterruptedException ex){Thread.currentThread().interrupt();}finally{e.close();}
        });server.start();realm="https://127.0.0.1:"+server.getAddress().getPort();
        try {
            try{pool=Class.forName("org.paranoid.text.RealtimeTransport").getConstructor(String.class,String.class).newInstance(realm,pin);}catch(ClassNotFoundException baseline){}
            for(int n=0;n<4;n++)if(!call("GET","/v2/messages?after=0&limit=20","",null).getString("status").equals("ok"))throw new AssertionError("response");
            if(ports.size()!=1)throw new AssertionError("warm requests must reuse pinned TLS: actual connections="+ports.size());
            Future<?> wait=workers.submit(()->{try{call("GET","/v2/events?after=0&limit=20","",null);}catch(Exception e){throw new RuntimeException(e);}});
            if(!waiting.await(2,TimeUnit.SECONDS))throw new AssertionError("wait not entered");
            Future<?> send=workers.submit(()->{try{call("POST","/v2/messages","{}",null);}catch(Exception e){throw new RuntimeException(e);}});
            send.get(2,TimeUnit.SECONDS);release.countDown();wait.get(2,TimeUnit.SECONDS);
            try{call("GET","/v2/redirect","",null);throw new AssertionError("redirect accepted");}catch(SyncCycle.Rejected expected){if(expected.status!=307)throw expected;}
            System.out.println("PASS real pinned TLS reused; blocked receive independent of send; redirects refused");
        }finally{release.countDown();if(pool!=null)pool.getClass().getMethod("close").invoke(pool);server.stop(0);handlers.shutdownNow();workers.shutdownNow();}
    }
}
