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

    private HttpsURLConnection open(String url)throws Exception {
        if(CookieHandler.getDefault()!=null)throw new IOException("ambient HTTP credentials forbidden");
        HttpsURLConnection c=(HttpsURLConnection)new URL(url).openConnection(Proxy.NO_PROXY);
        // System CA trust: paranoid.global uses Cloudflare/Let's Encrypt; APK SHA-256 provides content integrity.
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
        HttpsURLConnection c=open(UPDATE_BASE+"/android.json");long start=System.nanoTime();
        try {
            int status=c.getResponseCode();if(status==404)return null;if(status!=200)throw new IOException("metadata unavailable");
            headers(c,8192);ByteArrayOutputStream out=new ByteArrayOutputStream();
            try(InputStream in=c.getInputStream()){copy(in,out,8192,null,start);}
            return UpdateManifest.parse(out.toByteArray());
        }finally{c.disconnect();}
    }
    public File download(UpdateManifest m,File cache,Verifier verifier)throws Exception {
        File dir=new File(cache.getCanonicalFile(),"android-update");
        if(!Files.exists(dir.toPath(),LinkOption.NOFOLLOW_LINKS))Files.createDirectory(dir.toPath(),PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")));
        dir=UpdatePolicy.directory(cache);
        File temp=new File(dir,"download.part"),ready=new File(dir,"verified.apk");
        Files.deleteIfExists(temp.toPath());Files.deleteIfExists(ready.toPath());
        HttpsURLConnection c=open(UPDATE_BASE+"/"+m.sha256+".apk");long start=System.nanoTime();
        try {
            int status=c.getResponseCode();if(status!=200)throw new IOException("APK unavailable");
            headers(c,64*1024*1024);
            MessageDigest digest=MessageDigest.getInstance("SHA-256");
            long total;
            try(InputStream in=c.getInputStream();OutputStream out=new BufferedOutputStream(new FileOutputStream(temp))){total=copy(in,out,65536,digest,start);}
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
    private static String hex(MessageDigest d){StringBuilder sb=new StringBuilder();for(byte b:d.digest())sb.append(String.format("%02x",b));return sb.toString();}
    private static long copy(InputStream in,OutputStream out,int buf,MessageDigest digest,long start)throws IOException {
        byte[]b=new byte[buf];long total=0;int n;
        while((n=in.read(b))>=0){out.write(b,0,n);total+=n;if(digest!=null)digest.update(b,0,n);
            if(System.nanoTime()-start>55_000_000_000L)throw new IOException("transfer timeout");}
        return total;
    }
}
