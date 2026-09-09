package org.paranoid.text;

import org.json.JSONObject;
import javax.net.ssl.HttpsURLConnection;
import java.net.URL;
import java.io.*;
import java.nio.charset.StandardCharsets;

/** Same exact leaf/SPKI/SAN/validity TLS policy as the v0 Android adapter. */
public final class KeyTransport {
    private KeyTransport(){}
    public static JSONObject call(String realm,String pin,String method,String path,String body,String authorization) throws Exception {
        KeyClient.checkedRealm(realm);
        if(!path.startsWith("/v1/") || path.indexOf('#')>=0 || path.indexOf('\r')>=0 || path.indexOf('\n')>=0)throw new IOException("invalid path");
        HttpsURLConnection c=(HttpsURLConnection)new URL(realm+path).openConnection(java.net.Proxy.NO_PROXY);
        c.setSSLSocketFactory(PinnedTls.factory(new URL(realm).getHost(),pin));
        c.setInstanceFollowRedirects(false);c.setConnectTimeout(8000);c.setReadTimeout(8000);
        c.setRequestMethod(method);c.setRequestProperty("Accept","application/json");
        // Each request owns a fresh trust factory; do not strand cached idle sockets.
        c.setRequestProperty("Connection","close");
        if(authorization!=null)c.setRequestProperty("Authorization",authorization);
        try {
            if(!method.equals("GET")) {
                byte[] bytes=body.getBytes(StandardCharsets.UTF_8);c.setDoOutput(true);
                c.setRequestProperty("Content-Type","application/json");c.setFixedLengthStreamingMode(bytes.length);
                try(OutputStream out=c.getOutputStream()){out.write(bytes);}
            } else if(!body.isEmpty())throw new IOException("GET body rejected");
            int status=c.getResponseCode();if(status!=200)throw new SyncCycle.Rejected(status);
            ByteArrayOutputStream bytes=new ByteArrayOutputStream();
            try(InputStream in=c.getInputStream()) {byte[] buffer=new byte[4096];int n;
                while((n=in.read(buffer))!=-1){if(bytes.size()+n>2*1024*1024)throw new IOException("response limit");bytes.write(buffer,0,n);}}
            return new JSONObject(new String(bytes.toByteArray(),StandardCharsets.UTF_8));
        } finally {c.disconnect();}
    }
}
