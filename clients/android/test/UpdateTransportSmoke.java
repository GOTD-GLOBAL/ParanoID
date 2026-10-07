package org.paranoid.text;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;
import java.security.cert.Certificate;
import java.util.*;
import javax.net.ssl.*;

/** Offline URL adapter: exercises production constructor/wiring, NOT a TLS handshake. */
public final class UpdateTransportSmoke {
    static final byte[] PAYLOAD={1,2,3};
    static final SSLSocketFactory TLS=HttpsURLConnection.getDefaultSSLSocketFactory();
    static final HostnameVerifier HOST=HttpsURLConnection.getDefaultHostnameVerifier();
    static final List<Connection> connections=new ArrayList<>();
    static String mode;
    static UpdateManifest manifest;
    static long bytesRead, headerLength;
    static Path cache;
    interface Action {void run()throws Exception;}
    static void require(boolean value,String message){if(!value)throw new AssertionError(message);}
    static void reject(String message,Action action)throws Exception {
        try{action.run();throw new AssertionError("accepted: "+message);}
        catch(IOException e){if(!message.equals(e.getMessage()))throw new AssertionError("expected "+message+", got "+e,e);}
    }
    static UpdateManifest manifest(long size)throws Exception {
        StringBuilder hash=new StringBuilder();
        for(byte b:MessageDigest.getInstance("SHA-256").digest(PAYLOAD))hash.append(String.format("%02x",b&255));
        return UpdateManifest.parse(UpdateSmoke.JSON.replace(UpdateSmoke.repeat('a',64),hash.toString())
            .replace("\"apk_size\":3","\"apk_size\":"+size).getBytes(StandardCharsets.UTF_8));
    }
    static byte[] metadata() {
        return UpdateSmoke.JSON.replace(UpdateSmoke.repeat('a',64),manifest.sha256)
            .replace("\"apk_size\":3","\"apk_size\":"+manifest.apkSize).getBytes(StandardCharsets.UTF_8);
    }
    static final class Connection extends HttpsURLConnection {
        boolean disconnected,opened;
        final boolean meta;
        Connection(URL url){super(url);meta=url.getPath().equals("/updates/android.json");}
        void wiring() {
            require(getSSLSocketFactory()==TLS,"production TLS factory replaced");
            require(getHostnameVerifier()==HOST,"hostname verifier replaced");
            require(!getInstanceFollowRedirects() && !getUseCaches(),"redirect/cache enabled");
            require(getConnectTimeout()==8000 && getReadTimeout()==60000,"network deadlines changed");
            require(getRequestMethod().equals("GET"),"not GET");
            require("identity".equals(getRequestProperty("Accept-Encoding")),"encoding request");
            require("close".equals(getRequestProperty("Connection")),"connection lifetime");
            require("ParanoID-Android/1".equals(getRequestProperty("User-Agent")),"user agent");
            for(String name:getRequestProperties().keySet())require(Arrays.asList("Connection","Accept-Encoding","User-Agent").contains(name),"unexpected credential/header "+name);
        }
        public int getResponseCode()throws IOException {
            wiring();
            if(!meta && mode.equals("collision"))Files.createSymbolicLink(cache.resolve("android-update/download.part"),cache.resolve("text-state.enc"));
            return mode.equals("redirect")?302:mode.equals("absent")?404:200;
        }
        public long getContentLengthLong(){return meta?(mode.startsWith("metadata-")?-1:metadata().length):headerLength;}
        public String getHeaderField(String name){return name.equals("Location")?"https://attacker.invalid/no":null;}
        public InputStream getInputStream() {
            opened=true;
            if(meta && mode.startsWith("metadata-"))return new InputStream(){
                long left=1024*1024;
                public int read(){throw new AssertionError("unbuffered metadata");}
                public int read(byte[] b,int off,int length){if(left==0)return -1;int n=(int)Math.min(left,length);Arrays.fill(b,off,off+n,(byte)' ');left-=n;bytesRead+=n;return n;}
            };
            if(meta)return new ByteArrayInputStream(metadata());
            if(mode.startsWith("size-"))return new InputStream(){public int read()throws IOException{throw new IOException("fixture body reached");}};
            return new ByteArrayInputStream(PAYLOAD);
        }
        public void connect(){}
        public void disconnect(){disconnected=true;}
        public boolean usingProxy(){return false;}
        public String getCipherSuite(){throw new AssertionError("adapter is not TLS evidence");}
        public Certificate[] getLocalCertificates(){return null;}
        public Certificate[] getServerCertificates(){throw new AssertionError("adapter is not TLS evidence");}
    }
    static void installAdapter() {
        URL.setURLStreamHandlerFactory(protocol->new URLStreamHandler(){
            protected URLConnection openConnection(URL url){throw new AssertionError("explicit NO_PROXY required");}
            protected URLConnection openConnection(URL url,Proxy proxy) {
                require(protocol.equals("https") && proxy==Proxy.NO_PROXY,"non-HTTPS/proxy");
                require(url.getHost().equals("paranoid.global") && url.getPort()==-1 && url.getUserInfo()==null && url.getQuery()==null && url.getRef()==null,"not fixed credential-free origin: "+url);
                require(url.getPath().equals("/updates/android.json") || url.getPath().equals("/updates/"+manifest.sha256+".apk"),"wrong fixed route: "+url);
                Connection connection=new Connection(url);connections.add(connection);return connection;
            }
        });
    }
    static File download(UpdateClient client)throws Exception {
        return client.download(manifest,cache.toFile(),(file,m)->{
            require(file.getName().equals("download.part"),"premature promotion");
            if(mode.startsWith("header-") || mode.equals("collision"))return; // The boundary under test precedes this gate.
            require(Files.getPosixFilePermissions(file.toPath()).equals(PosixFilePermissions.fromString("rw-------")),"temp not mode 0600");
            require(Files.getPosixFilePermissions(file.toPath().getParent()).equals(PosixFilePermissions.fromString("rwx------")),"directory not mode 0700");
        });
    }
    static void test(String name)throws Exception {
        mode=name;connections.clear();bytesRead=0;
        cache=Files.createTempDirectory("update-adapter-");
        Path state=cache.resolve("text-state.enc"),dir=cache.resolve("android-update"),part=dir.resolve("download.part"),ready=dir.resolve("verified.apk");
        Files.write(state,PAYLOAD);
        manifest=manifest(name.equals("size-64")?65L*1024*1024+17:name.equals("size-512")?512_000_001L:3);
        headerLength=manifest.apkSize;
        boolean success=false;
        try {
            UpdateClient client=new UpdateClient();
            if(name.startsWith("metadata-")) {
                reject("size exceeded declared 8192",()->client.check());
                require(bytesRead<=16384,"metadata read beyond fixed bound: "+bytesRead);
            } else if(name.startsWith("size-")) {
                require(cache.toFile().getUsableSpace()>manifest.apkSize,"fixture requires actual free disk > "+manifest.apkSize);
                reject("fixture body reached",()->download(client));
                require(connections.size()==1 && connections.get(0).opened,"large header blocked before body");
            } else if(name.equals("disk")) {
                long available=cache.toFile().getUsableSpace();
                require(available>0 && available<Long.MAX_VALUE-1048576,"disk fixture space");
                // Larger than ACTUAL free space, not merely a manifest above the old cap.
                manifest=manifest(available+1048576);
                Files.createDirectory(dir);Files.write(part,PAYLOAD);Files.write(ready,PAYLOAD);
                reject("insufficient update cache space",()->download(client));
                require(connections.isEmpty(),"disk failure opened connection");
            } else if(name.equals("header-small") || name.equals("header-big")) {
                headerLength=name.equals("header-small")?2:4;
                reject(name.equals("header-small")?"APK length header":"response size",()->download(client));
                require(!connections.get(0).opened,"wrong header consumed body");
            } else if(name.equals("redirect")) {
                reject("metadata unavailable",()->client.check());
                require(connections.size()==1 && !connections.get(0).opened,"redirect followed/read");
            } else if(name.equals("absent")) {
                require(client.check()==null,"404 not absent");
            } else if(name.equals("cookie")) {
                CookieHandler.setDefault(new CookieManager());
                try{reject("ambient HTTP credentials forbidden",()->client.check());}finally{CookieHandler.setDefault(null);}
                require(connections.isEmpty(),"cookie guard made request");
            } else if(name.equals("collision")) {
                try{download(client);throw new AssertionError("non-exclusive temp followed collision");}
                catch(FileAlreadyExistsException expected){}
            } else {
                if(name.equals("links")) {
                    Files.createDirectory(dir,PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")));
                    Files.createSymbolicLink(part,state);Files.createSymbolicLink(ready,state);
                }
                require(client.check().apkSize==3,"default metadata parse");
                File file=download(client);UpdateClient.verifyBytes(file,manifest);
                require(file.toPath().equals(ready),"not fixed ready path");success=true;
            }
            for(Connection c:connections)require(c.disconnected,"connection leak");
            require(!Files.exists(part,LinkOption.NOFOLLOW_LINKS),"partial leak");
            if(!success)require(!Files.exists(ready,LinkOption.NOFOLLOW_LINKS),"unverified ready leak");
            require(Arrays.equals(Files.readAllBytes(state),PAYLOAD),"state/symlink target modified");
        } finally {
            try(java.util.stream.Stream<Path> files=Files.walk(cache)){for(Path p:(Iterable<Path>)files.sorted(Comparator.reverseOrder())::iterator)Files.delete(p);}
        }
        System.out.println("UpdateTransportSmoke "+name+" PASS (offline host adapter, not TLS/device evidence)");
    }
    public static void main(String[] args)throws Exception {
        installAdapter();
        if(args.length>0){test(args[0]);return;}
        for(String name:new String[]{"metadata-unknown","size-64","size-512","disk","header-small","header-big","private","links","collision","wiring","redirect","absent","cookie"})test(name);
    }
}
