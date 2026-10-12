package org.paranoid.text;

import javax.net.ssl.HttpsURLConnection;
import java.net.*;
import java.io.*;
import java.nio.channels.Channels;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.HashSet;

/**
 * Downloads update manifest and APK from the fixed update service at paranoid.global.
 * Independent of the selected messenger server (RFC0013 fixed-service reconciliation).
 * Production retains platform CA and hostname validation. TLS and SHA-256 do not
 * grant signer authority: APK identity/signer checks and installation consent are separate.
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
        this.baseUrl = KeyClient.checkedRealm(realm);
        this.pin = PinnedTls.checkedPin(pin);
        this.legacyPaths = true;
    }

    private HttpsURLConnection open(String url)throws Exception {
        if(CookieHandler.getDefault()!=null)throw new IOException("ambient HTTP credentials forbidden");
        if(pin!=null && !url.startsWith("https://"))throw new IOException("cleartext forbidden");
        HttpsURLConnection c=(HttpsURLConnection)new URL(url).openConnection(Proxy.NO_PROXY);
        if(pin!=null)c.setSSLSocketFactory(PinnedTls.factory(new URL(url).getHost(),pin));
        // Production leaves the platform TLS factory and hostname verifier unchanged.
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
            try(InputStream in=c.getInputStream()){copy(in,out,8192,null,start,8192);}
            return UpdateManifest.parse(out.toByteArray());
        }finally{c.disconnect();}
    }
    public File download(UpdateManifest m,File cache,Verifier verifier)throws Exception {
        File dir=new File(cache.getCanonicalFile(),"android-update");
        if(!Files.exists(dir.toPath(),LinkOption.NOFOLLOW_LINKS))Files.createDirectory(dir.toPath(),PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")));
        dir=UpdatePolicy.directory(cache);
        File temp=new File(dir,"download.part"),ready=new File(dir,"verified.apk");
        boolean promoted=false;HttpsURLConnection c=null;long start=System.nanoTime();
        try {
            // Only dedicated cache names; deleting a link never deletes its target.
            Files.deleteIfExists(temp.toPath());Files.deleteIfExists(ready.toPath());
            // Advisory under concurrent writers, not a quota or an APK size ceiling.
            if(m.apkSize>dir.getUsableSpace())throw new IOException("insufficient update cache space");
            c=open(legacyPaths ? baseUrl+"/v2/updates/android/apk/"+m.sha256 : baseUrl+"/"+m.sha256+".apk");
            int status=c.getResponseCode();if(status!=200)throw new IOException("APK unavailable");
            headers(c,m.apkSize);
            long length=c.getContentLengthLong();
            if(length>=0 && length!=m.apkSize)throw new IOException("APK length header");
            MessageDigest digest=MessageDigest.getInstance("SHA-256");
            long total;
            // One exclusive/no-follow creation with mode 0600, not create-then-reopen.
            try(OutputStream out=Channels.newOutputStream(Files.newByteChannel(temp.toPath(),
                    new HashSet<OpenOption>(Arrays.asList(StandardOpenOption.CREATE_NEW,StandardOpenOption.WRITE,LinkOption.NOFOLLOW_LINKS)),
                    PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------"))));
                InputStream in=c.getInputStream()){total=copy(in,out,65536,digest,start,m.apkSize);}
            verifyBytes(temp,m,digest,total);
            verifier.verify(temp,m);
            Files.move(temp.toPath(),ready.toPath(),StandardCopyOption.ATOMIC_MOVE);
            promoted=true;return ready;
        }finally{
            if(c!=null)c.disconnect();
            try{Files.deleteIfExists(temp.toPath());}finally{if(!promoted)Files.deleteIfExists(ready.toPath());}
        }
    }
    /** Verify SHA-256 and size of an already-downloaded APK. */
    public static void verifyBytes(File apk,UpdateManifest m)throws Exception {
        MessageDigest digest=MessageDigest.getInstance("SHA-256");
        long total;
        try(InputStream in=Files.newInputStream(apk.toPath(),LinkOption.NOFOLLOW_LINKS)){total=copy(in,new OutputStream(){public void write(byte[]b,int o,int l){}public void write(int b){}},65536,digest,System.nanoTime(),m.apkSize);}
        if(total!=m.apkSize||!hex(digest).equals(m.sha256))throw new IOException("APK copy checksum/size mismatch");
    }
    private static void verifyBytes(File apk,UpdateManifest m,MessageDigest digest,long total)throws IOException {
        if(total!=m.apkSize || !hex(digest).equals(m.sha256))throw new IOException("APK download checksum/size mismatch");
    }
    /** Overflow-safe accumulation: total + n must not exceed declared. Package-private for UpdateCopySmoke. */
    static long checkedTotal(long total,int n,long declared)throws IOException {
        if(n<0||total<0||declared<0)throw new IOException("negative size");
        if(total>declared || n>declared-total)throw new IOException("size exceeded declared "+declared);
        return total+n;
    }
    private static String hex(MessageDigest d){StringBuilder sb=new StringBuilder();for(byte b:d.digest())sb.append(String.format("%02x",b));return sb.toString();}
    private static long copy(InputStream in,OutputStream out,int buf,MessageDigest digest,long start,long declared)throws IOException {
        byte[]b=new byte[buf];long total=0;int n;
        while((n=in.read(b))>=0){
            total=checkedTotal(total,n,declared);
            out.write(b,0,n);
            if(digest!=null)digest.update(b,0,n);
            if(System.nanoTime()-start>55_000_000_000L)throw new IOException("transfer timeout");}
        return total;
    }
}
