import org.paranoid.text.PinnedTls;
import com.sun.net.httpserver.HttpsServer;
import com.sun.net.httpserver.HttpsConfigurator;
import javax.net.ssl.*;
import java.net.*;
import java.io.*;
import java.security.*;
import java.security.cert.X509Certificate;
import java.util.concurrent.atomic.AtomicInteger;

public final class TlsSmoke {
    static final char[] PASSWORD="test-only".toCharArray();
    static String pin(X509Certificate c)throws Exception {
        byte[] digest=MessageDigest.getInstance("SHA-256").digest(c.getPublicKey().getEncoded());StringBuilder s=new StringBuilder();
        for(byte b:digest)s.append(String.format("%02x",b&255));return s.toString();
    }
    static void check(String storePath,String pinValue,boolean shouldConnect)throws Exception {
        KeyStore store=KeyStore.getInstance("PKCS12");try(InputStream in=new FileInputStream(storePath)){store.load(in,PASSWORD);}
        KeyManagerFactory km=KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());km.init(store,PASSWORD);
        SSLContext context=SSLContext.getInstance("TLS");context.init(km.getKeyManagers(),null,null);
        HttpsServer server=HttpsServer.create(new InetSocketAddress("127.0.0.1",0),0);
        server.setHttpsConfigurator(new HttpsConfigurator(context));AtomicInteger requests=new AtomicInteger();
        server.createContext("/",exchange->{requests.incrementAndGet();byte[] body="ok".getBytes(java.nio.charset.StandardCharsets.UTF_8);exchange.sendResponseHeaders(200,body.length);try(OutputStream out=exchange.getResponseBody()){out.write(body);}});
        server.start();HttpsURLConnection connection=null;
        try {
            URL url=new URL("https://127.0.0.1:"+server.getAddress().getPort()+"/");connection=(HttpsURLConnection)url.openConnection();
            connection.setSSLSocketFactory(PinnedTls.factory(url.getHost(),pinValue));
            connection.setInstanceFollowRedirects(false);connection.setConnectTimeout(2000);connection.setReadTimeout(2000);
            connection.setRequestProperty("Authorization","Bearer synthetic-fixture");
            boolean connected=false;
            try {connected=connection.getResponseCode()==200;}catch(IOException expected){if(shouldConnect)throw expected;}
            if(connected!=shouldConnect)throw new AssertionError("unexpected TLS acceptance");
            if(!shouldConnect && requests.get()!=0)throw new AssertionError("HTTP credentials reached rejected peer");
        } finally {if(connection!=null)connection.disconnect();server.stop(0);}
    }
    public static void main(String[] args)throws Exception {
        KeyStore store=KeyStore.getInstance("PKCS12");try(InputStream in=new FileInputStream(args[0])){store.load(in,PASSWORD);}
        String pin=pin((X509Certificate)store.getCertificate("tls"));
        check(args[0],pin,true);
        check(args[0],"00".repeat(32),false);
        check(args[1],pin,false); // Same pinned key, wrong IP SAN.
        check(args[2],pin,false); // Same pinned key, expired certificate.
        try {PinnedTls.factory("127.0.0.1","");throw new AssertionError("missing pin accepted");}catch(GeneralSecurityException expected){}
        SSLSocket socket=(SSLSocket)PinnedTls.factory("127.0.0.1",pin).createSocket();
        for(String p:socket.getEnabledProtocols())if(!p.equals("TLSv1.2")&&!p.equals("TLSv1.3"))throw new AssertionError("legacy TLS enabled");socket.close();
        System.out.println("Pinned TLS: PASS (real JVM handshakes: correct key accepted; wrong key/SAN/expiry rejected before HTTP)");
    }
}
