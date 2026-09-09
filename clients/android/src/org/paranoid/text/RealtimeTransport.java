package org.paranoid.text;

import org.json.JSONObject;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLSocketFactory;
import java.net.URL;
import java.net.Proxy;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.Semaphore;

/** A single saved realm/SPKI pool. Network workers only; at most two requests. */
public final class RealtimeTransport implements AutoCloseable {
    private final String realm;
    private final SSLSocketFactory factory;
    private final Semaphore capacity=new Semaphore(2);
    private final Set<HttpsURLConnection> active=new HashSet<>();
    private boolean closed;
    public RealtimeTransport(String realm,String pin)throws Exception {
        this.realm=KeyClient.checkedRealm(realm);
        factory=PinnedTls.factory(new URL(realm).getHost(),pin);
    }
    public JSONObject call(String method,String path,String body,String authorization)throws Exception {
        if(!(path.equals("/health")||path.startsWith("/v2/")) || path.indexOf('#')>=0 || path.indexOf('\r')>=0 || path.indexOf('\n')>=0)
            throw new IOException("invalid transport path");
        if(!method.equals("GET")&&!method.equals("POST"))throw new IOException("invalid transport method");
        if(method.equals("GET")&&!body.isEmpty())throw new IOException("GET body rejected");
        if(!capacity.tryAcquire())throw new IOException("transport capacity");
        HttpsURLConnection c=null;boolean reusable=false;
        try {
            c=(HttpsURLConnection)new URL(realm+path).openConnection(Proxy.NO_PROXY);
            synchronized(active){if(closed)throw new IOException("transport closed");active.add(c);}
            c.setSSLSocketFactory(factory);c.setInstanceFollowRedirects(false);
            c.setConnectTimeout(8000);c.setReadTimeout(path.startsWith("/v2/events?")?30000:8000);
            c.setRequestMethod(method);c.setRequestProperty("Accept","application/json");
            if(authorization!=null)c.setRequestProperty("Authorization",authorization);
            if(method.equals("POST")) {
                byte[] bytes=body.getBytes(StandardCharsets.UTF_8);
                if(bytes.length>65536)throw new IOException("request limit");
                c.setDoOutput(true);c.setRequestProperty("Content-Type","application/json");c.setFixedLengthStreamingMode(bytes.length);
                try(OutputStream out=c.getOutputStream()){out.write(bytes);}
            }
            int status=c.getResponseCode();
            byte[] response;
            InputStream input=status==200?c.getInputStream():c.getErrorStream();
            if(input==null)response=new byte[0];
            else try(InputStream in=input;ByteArrayOutputStream out=new ByteArrayOutputStream()) {
                byte[] bytes=new byte[4096];int n;int limit=status==200?2*1024*1024:4096;
                while((n=in.read(bytes))!=-1){if(out.size()+n>limit)throw new IOException("response limit");out.write(bytes,0,n);}
                response=out.toByteArray();
            }
            if(status!=200) {
                String code="";
                try{String candidate=new JSONObject(new String(response,StandardCharsets.UTF_8)).optString("error","");if(candidate.matches("[a-z_]{1,40}"))code=candidate;}catch(Exception ignored){}
                throw new SyncCycle.Rejected(status,code);
            }
            JSONObject parsed=new JSONObject(new String(response,StandardCharsets.UTF_8));
            reusable=true;return parsed;
        } finally {
            if(c!=null){synchronized(active){active.remove(c);}if(!reusable)c.disconnect();}
            capacity.release();
        }
    }
    /** Cancel current I/O without replacing the saved per-realm trust factory. */
    public void cancelActive() {
        HttpsURLConnection[] current;
        synchronized(active){current=active.toArray(new HttpsURLConnection[0]);}
        for(HttpsURLConnection c:current)c.disconnect();
    }
    @Override public void close(){synchronized(active){closed=true;}cancelActive();}
}
