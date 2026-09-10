package org.paranoid.text;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.Proxy;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLSocketFactory;
import org.json.JSONObject;

/** One negotiation-only connection to the saved pinned origin. No shared text I/O. */
final class VoiceRelayTransport implements AutoCloseable {
    private final URL endpoint;
    private final SSLSocketFactory factory;
    private HttpsURLConnection active;
    private boolean closed;

    VoiceRelayTransport(String realm,String pin)throws Exception {
        String origin=KeyClient.checkedRealm(realm);
        endpoint=new URL(origin+"/v2/voice/turn");
        factory=PinnedTls.factory(endpoint.getHost(),pin);
    }
    byte[] get(String authorization)throws Exception {
        if(authorization==null||!authorization.startsWith("ParanoidSessionV2 ")
                ||authorization.length()>4096)throw new IOException("voice authorization unavailable");
        HttpsURLConnection connection=(HttpsURLConnection)endpoint.openConnection(Proxy.NO_PROXY);
        synchronized(this){
            if(closed||active!=null)throw new IOException("voice transport unavailable");
            active=connection;
        }
        try {
            connection.setSSLSocketFactory(factory);connection.setInstanceFollowRedirects(false);
            connection.setUseCaches(false);connection.setConnectTimeout(8000);connection.setReadTimeout(8000);
            connection.setRequestMethod("GET");connection.setRequestProperty("Authorization",authorization);
            connection.setRequestProperty("Accept","application/json");
            connection.setRequestProperty("Cache-Control","no-store");
            connection.setRequestProperty("Connection","close");
            int status=connection.getResponseCode();
            InputStream input=status==200?connection.getInputStream():connection.getErrorStream();
            byte[] bytes;
            if(input==null)bytes=new byte[0];
            else try(InputStream stream=input;ByteArrayOutputStream output=new ByteArrayOutputStream()){
                byte[] buffer=new byte[1024];int count,limit=status==200?2048:4096;
                while((count=stream.read(buffer))!=-1){
                    if(output.size()+count>limit)throw new IOException("voice response limit");
                    output.write(buffer,0,count);
                }
                bytes=output.toByteArray();
            }
            if(status!=200){
                String code="";
                try{String value=new JSONObject(new String(bytes,StandardCharsets.UTF_8)).optString("error","");
                    if(value.matches("[a-z_]{1,40}"))code=value;
                }catch(Exception ignored){}
                throw new SyncCycle.Rejected(status,code);
            }
            return bytes;
        }finally{
            synchronized(this){if(active==connection)active=null;}
            connection.disconnect();
        }
    }
    @Override public void close(){
        HttpsURLConnection connection;
        synchronized(this){closed=true;connection=active;}
        if(connection!=null)connection.disconnect();
    }
}
