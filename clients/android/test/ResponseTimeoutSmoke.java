package org.paranoid.text;

import com.sun.net.httpserver.HttpsServer;
import com.sun.net.httpserver.HttpsConfigurator;
import javax.net.ssl.*;
import java.net.*;
import java.io.*;
import java.security.*;
import java.security.cert.X509Certificate;
import java.util.*;
import java.util.concurrent.*;

/** Real loopback TLS and shipped transports; no credentials or hosted traffic. */
public final class ResponseTimeoutSmoke {
    public static void main(String[] args)throws Exception {
        KeyStore store=KeyStore.getInstance("PKCS12");
        try(InputStream in=new FileInputStream(args[0])){store.load(in,"test-only".toCharArray());}
        KeyManagerFactory km=KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        km.init(store,"test-only".toCharArray());
        SSLContext ssl=SSLContext.getInstance("TLS");ssl.init(km.getKeyManagers(),null,null);
        StringBuilder hex=new StringBuilder();
        for(byte b:MessageDigest.getInstance("SHA-256").digest(((X509Certificate)store.getCertificate("tls")).getPublicKey().getEncoded()))hex.append(String.format("%02x",b&255));
        String pin=hex.toString();
        ExecutorService handlers=Executors.newCachedThreadPool();
        try {
            // Each round uses the actual server bound or a valid response after the old 8s bound.
            for(int status:new int[]{200,408}) {
                HttpsServer server=HttpsServer.create(new InetSocketAddress("127.0.0.1",0),0);
                server.setHttpsConfigurator(new HttpsConfigurator(ssl));server.setExecutor(handlers);
                server.createContext("/",e->{
                    try {
                        while(e.getRequestBody().read()!=-1){}
                        Thread.sleep(status==200?9000:10000);
                        // Update check accepts 404 as no published update; all others accept JSON 200.
                        int reply=status==200&&e.getRequestURI().getPath().contains("updates")?404:status;
                        byte[] bytes=(status==408?"{\"error\":\"request_timeout\"}":"{}").getBytes("UTF-8");
                        e.sendResponseHeaders(reply,bytes.length);
                        try(OutputStream out=e.getResponseBody()){out.write(bytes);}
                    }catch(InterruptedException ex){Thread.currentThread().interrupt();}
                    catch(IOException expectedAfterTimeout){}finally{e.close();}
                });server.start();
                String realm="https://127.0.0.1:"+server.getAddress().getPort();
                ExecutorService callers=Executors.newFixedThreadPool(4);
                List<Future<?>> results=new ArrayList<>();
                try {
                    for(String mode:new String[]{"realtime","key","voice","update"}) {
                        results.add(callers.submit(()->{
                            try {
                                if(mode.equals("realtime"))try(RealtimeTransport t=new RealtimeTransport(realm,pin)){t.call("GET","/v2/messages?after=0&limit=20","",null);}
                                else if(mode.equals("key"))KeyTransport.call(realm,pin,"POST","/v2/auth/challenge","{}",null);
                                else if(mode.equals("voice"))try(VoiceRelayTransport t=new VoiceRelayTransport(realm,pin)){t.get("ParanoidSessionV2 synthetic-fixture");}
                                else new UpdateClient(realm,pin).check();
                                if(status==408)throw new AssertionError(mode+" accepted 408");
                            }catch(SocketTimeoutException early){throw new AssertionError(mode+" gave up before the server reply",early);}
                            catch(SyncCycle.Rejected rejected){if(status!=408||rejected.status!=408)throw new AssertionError(mode+" unexpected status",rejected);}
                            catch(IOException failure){if(!mode.equals("update")||status!=408||!"metadata unavailable".equals(failure.getMessage()))throw new RuntimeException(failure);}
                            catch(Exception failure){throw new RuntimeException(failure);}
                            System.out.println("PASS "+mode+" delayed "+status);
                        }));
                    }
                    int failures=0;
                    for(Future<?> result:results)try{result.get(25,TimeUnit.SECONDS);}
                    catch(ExecutionException failure){failures++;System.err.println("FAIL "+failure.getCause());}
                    if(failures!=0)throw new AssertionError("delayed response failures: "+failures);
                }finally{server.stop(0);callers.shutdownNow();}
            }
        }finally{handlers.shutdownNow();}
    }
}
