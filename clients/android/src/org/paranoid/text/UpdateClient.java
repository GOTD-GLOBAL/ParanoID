package org.paranoid.text;

import javax.net.ssl.HttpsURLConnection;
import java.net.*;
import java.io.*;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;

/**
 * Downloads update manifest and APK from the fixed update service at paranoid.global.
 * Independent of which messenger server the app is connected to (owner decision 2026-10-05).
 * Uses standard HTTPS with system CA trust (Cloudflare/Let's Encrypt) — no pin needed
 * because paranoid.global is a well-known domain with certificate transparency logging.
 * The APK is verified by SHA-256 and signature before installation regardless.
 */
public final class UpdateClient {
    public interface Verifier {void verify(File apk,UpdateManifest manifest)throws Exception;}

    /** Fixed update service URL — never the messenger server. */
    public static final String UPDATE_BASE = "https://paranoid.global/updates";

    private final String baseUrl;
    private final String pin;         // null = system CA; non-null = pinned TLS (test only)
    private final boolean legacyPaths; // true = /v2/updates/android layout (test server)

    /** Production constructor: always uses paranoid.global/updates with system CA trust. */
    public UpdateClient() { this.baseUrl = UPDATE_BASE; this.pin = null; this.legacyPaths = false; }

    /** Test constructor: connects to a local test server using its old /v2/updates/android layout. */
    public UpdateClient(String realm, String pin) throws Exception {
        this.baseUrl = realm;
        this.pin = PinnedTls.checkedPin(pin);
        this.legacyPaths = true;
    }

    private HttpsURLConnection open(String url)throws Exception {
        if(CookieHandler.getDefault()!=null)throw new IOException("ambient HTTP credentials forbidden");
        if(pin!=null && !url.startsWith("https://"))throw new IOException("cleartext forbidden");
        HttpsURLConnection c=(HttpsURLConnection)new URL(url).openConnection(Proxy.NO_PROXY);
        if(pin!=null)c.setSSLSocketFactory(PinnedTls.factory(new URL(url).getHost(),pin));
        // else: system CA trust — paranoid.global uses Cloudflare/Let's Encrypt; APK SHA-256 provides content integrity.
        c.setInstanceFollowRedirects(false);c.setUseCaches(false);c.setConnectTimeout(8000);c.setReadTimeout(60000);
        c.setRequestMethod("GET");c.setRequestProperty("Connection","close");c.setRequestProperty("Accept-Encoding","identity");
        c.setRequestProperty("User-Agent","ParanoID-Android/1");
        return c;
    }
    private static void headers(HttpsURLConnection c,long limit)throws IOException {
        String encoding=c.getHeaderField("Content-Encoding");
        if(encoding!=null && !encoding.equalsIgnoreCase("identity"))throw new IOException("encoded response forbidden");
        if(c.getContentLengthLong()>limit)throw new IOException("response size");
    }
    public UpdateManifest check()throws Exception {
        HttpsURLConnection c=open(legacyPaths ? baseUrl+"/v2/updates/android" : baseUrl+"/android.json");long start=System.nanoTime();
        try {
            int status=c.getResponseCode();if(status==404)return null;if(status!=200)throw new IOException("metadata unavailable");
            headers(c,8192);ByteArrayOutputStream out=new ByteArrayOutputStream();
            try(InputStream in=c.getInputStream()){copy(in,out,8192,null,start);}
            return UpdateManifest.parse(out.toByteArray());
        }finally{c.disconnect();}
    }
    public File download(UpdateManifest m,File cache,Verifier verifier)throws Exception {
        if(m.apkSize>512_000_000L)throw new IOException("insufficient update cache space");
        File dir=new File(cache.getCanonicalFile(),"android-update");
        if(!Files.exists(dir.toPath(),LinkOption.NOFOLLOW_LINKS))Files.createDirectory(dir.toPath(),PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")));
        dir=UpdatePolicy.directory(cache);
        File temp=new File(dir,"download.part"),ready=new File(dir,"verified.apk");
        Files.deleteIfExists(temp.toPath());Files.deleteIfExists(ready.toPath());
        HttpsURLConnection c=open(legacyPaths ? baseUrl+"/v2/updates/android/apk/"+m.sha256 : baseUrl+"/"+m.sha256+".apk");long start=System.nanoTime();
        try {
            int status=c.getResponseCode();if(status!=200)throw new IOException("APK unavailable");
            headers(c,64*1024*1024);
            MessageDigest digest=MessageDigest.getInstance("SHA-256");
            long total;
            try(InputStream in=c.getInputStream();OutputStream out=new BufferedOutputStream(new FileOutputStream(temp))){total=copy(in,out,65536,digest,start,m.apkSize);}
            verifyBytes(temp,m,digest,total);
            verifier.verify(temp,m);
            Files.move(temp.toPath(),ready.toPath(),StandardCopyOption.ATOMIC_MOVE);
            return ready;
        }finally{c.disconnect();Files.deleteIfExists(temp.toPath());}
    }
    /** Verify SHA-256 and size of an already-downloaded APK. */
    public static void verifyBytes(File apk,UpdateManifest m)throws Exception {
        MessageDigest digest=MessageDigest.getInstance("SHA-256");
        long total;
        try(InputStream in=new BufferedInputStream(new FileInputStream(apk))){total=copy(in,new OutputStream(){public void write(byte[]b,int o,int l){}public void write(int b){}},65536,digest,System.nanoTime());}
        if(total!=m.apkSize||!hex(digest).equals(m.sha256))throw new IOException("APK copy checksum/size mismatch");
    }
    private static void verifyBytes(File apk,UpdateManifest m,MessageDigest digest,long total)throws IOException {
        if(total!=m.apkSize || !hex(digest).equals(m.sha256))throw new IOException("APK download checksum/size mismatch");
    }
    /** Overflow-safe accumulation: total + n must not exceed declared. Package-private for UpdateCopySmoke. */
    static long checkedTotal(long total,int n,long declared)throws IOException {
        if(n<0||total<0||declared<0)throw new IOException("negative size");
        long next=total+n;
        if(next<total||next>declared)throw new IOException("size exceeded declared "+declared);
        return next;
    }
    private static String hex(MessageDigest d){StringBuilder sb=new StringBuilder();for(byte b:d.digest())sb.append(String.format("%02x",b));return sb.toString();}
    private static long copy(InputStream in,OutputStream out,int buf,MessageDigest digest,long start)throws IOException {
        return copy(in,out,buf,digest,start,Long.MAX_VALUE);
    }
    private static long copy(InputStream in,OutputStream out,int buf,MessageDigest digest,long start,long declared)throws IOException {
        byte[]b=new byte[buf];long total=0;int n;
        while((n=in.read(b))>=0){out.write(b,0,n);
            total=checkedTotal(total,n,declared);
            if(digest!=null)digest.update(b,0,n);
            if(System.nanoTime()-start>55_000_000_000L)throw new IOException("transfer timeout");}
        return total;
    }
}
