package org.paranoid.text;

import javax.net.ssl.HttpsURLConnection;
import java.net.*;
import java.io.*;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;

/** No credentials, persistence callbacks, redirects, proxies or arbitrary update URLs. */
public final class UpdateClient {
    public interface Verifier {void verify(File apk,UpdateManifest manifest)throws Exception;}
    private final String realm,pin;
    public UpdateClient(String realm,String pin)throws Exception {
        this.realm=KeyClient.checkedRealm(realm);this.pin=PinnedTls.checkedPin(pin);
    }
    private HttpsURLConnection open(String path)throws Exception {
        // This app has no cookie/auth handler. Fail closed if a future dependency adds one.
        if(CookieHandler.getDefault()!=null)throw new IOException("ambient HTTP credentials forbidden");
        HttpsURLConnection c=(HttpsURLConnection)new URL(realm+path).openConnection(Proxy.NO_PROXY);
        c.setSSLSocketFactory(PinnedTls.factory(new URL(realm).getHost(),pin));
        c.setInstanceFollowRedirects(false);c.setUseCaches(false);c.setConnectTimeout(8000);c.setReadTimeout(8000);
        c.setRequestMethod("GET");c.setRequestProperty("Connection","close");c.setRequestProperty("Accept-Encoding","identity");
        return c;
    }
    private static void headers(HttpsURLConnection c,long limit)throws IOException {
        String encoding=c.getHeaderField("Content-Encoding");
        if(encoding!=null && !encoding.equalsIgnoreCase("identity"))throw new IOException("encoded response forbidden");
        if(c.getContentLengthLong()>limit)throw new IOException("response size");
    }
    public UpdateManifest check()throws Exception {
        HttpsURLConnection c=open("/v2/updates/android");long start=System.nanoTime();
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
        // Exact dedicated names only. Deleting a symlink deletes the link, never its target.
        Files.deleteIfExists(temp.toPath());Files.deleteIfExists(ready.toPath());
        boolean promoted=false;HttpsURLConnection c=null;long start=System.nanoTime();
        try {
            c=open("/v2/updates/android/apk/"+m.sha256);
            if(c.getResponseCode()!=200)throw new IOException("APK unavailable");headers(c,m.apkSize);
            if(c.getContentLengthLong()>=0 && c.getContentLengthLong()!=m.apkSize)throw new IOException("APK length header");
            MessageDigest hash=MessageDigest.getInstance("SHA-256");long size;
            Files.createFile(temp.toPath(),PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")));
            try(InputStream in=c.getInputStream();OutputStream out=Files.newOutputStream(temp.toPath(),StandardOpenOption.WRITE,LinkOption.NOFOLLOW_LINKS)){
                size=copy(in,out,m.apkSize,hash,start);
            }
            if(size!=m.apkSize || !hex(hash.digest()).equals(m.sha256))throw new IOException("APK checksum/size");
            verifier.verify(temp,m);
            Files.move(temp.toPath(),ready.toPath(),StandardCopyOption.ATOMIC_MOVE);
            promoted=true;return ready;
        }finally{if(c!=null)c.disconnect();Files.deleteIfExists(temp.toPath());if(!promoted)Files.deleteIfExists(ready.toPath());}
    }
    private static long copy(InputStream in,OutputStream out,long limit,MessageDigest hash,long start)throws IOException {
        long total=0;byte[] buffer=new byte[8192];int n;
        while((n=in.read(buffer))!=-1){if(System.nanoTime()-start>60000000000L || Thread.currentThread().isInterrupted())throw new IOException("update deadline");
            total+=n;if(total>limit)throw new IOException("download size");out.write(buffer,0,n);if(hash!=null)hash.update(buffer,0,n);
        }return total;
    }
    public static void verifyBytes(File apk,UpdateManifest m)throws Exception {
        MessageDigest hash=MessageDigest.getInstance("SHA-256");long size;
        try(InputStream in=Files.newInputStream(apk.toPath(),LinkOption.NOFOLLOW_LINKS)){
            size=copy(in,new OutputStream(){public void write(int b){}public void write(byte[] b,int o,int n){}},m.apkSize,hash,System.nanoTime());
        }
        if(size!=m.apkSize || !hex(hash.digest()).equals(m.sha256))throw new IOException("cached APK changed");
    }
    private static String hex(byte[] bytes){StringBuilder s=new StringBuilder();for(byte b:bytes)s.append(String.format(java.util.Locale.ROOT,"%02x",b&255));return s.toString();}
}
