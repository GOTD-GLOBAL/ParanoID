package org.paranoid.text;
import java.io.*;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.*;
import javax.net.ssl.SSLHandshakeException;

/** A rejection is a checked, expected cause, never merely a failing JVM. */
public final class UpdateNetworkSmoke {
    public static void main(String[] args)throws Exception {
        String mode=args[2], expected=args.length>3?args[3]:"";
        if(mode.equals("origin")) {
            try {new UpdateClient(args[0],args[1]);throw new AssertionError("malformed origin accepted by constructor");}
            catch(IOException e) {if(!"HTTPS origin required".equals(e.getMessage()))throw e;}
            System.out.println("REJECT origin");return;
        }
        if(mode.equals("cookie"))java.net.CookieHandler.setDefault(new java.net.CookieManager());
        Path cache=Files.createTempDirectory("update-download-");
        Files.write(cache.resolve("text-state.enc"),new byte[]{7,8,9});
        boolean success=false;
        try {
            UpdateClient client=new UpdateClient(args[0],args[1]);
            UpdateManifest m=client.check();
            if(mode.equals("absent")) {
                if(m!=null)throw new AssertionError("404 must be absent");
                System.out.println("absent PASS");return;
            }
            if(m==null)throw new AssertionError("missing manifest");
            File apk=client.download(m,cache.toFile(),(file,manifest)->{
                if(file.getName().equals("verified.apk"))throw new AssertionError("promotion before verification");
                if(!Files.getPosixFilePermissions(file.toPath()).equals(PosixFilePermissions.fromString("rw-------")))throw new AssertionError("non-private partial");
                if(mode.equals("reject-apk"))throw new IOException("APK rejected");
            });
            if(!expected.isEmpty())throw new AssertionError("expected rejection: "+expected);
            if(!apk.getName().equals("verified.apk") || apk.length()!=m.apkSize)throw new AssertionError("verified cache");
            UpdateClient.verifyBytes(apk,m);
            success=true;System.out.println("download PASS "+apk.length());
        } catch(IOException e) {
            if(expected.isEmpty())throw e;
            if(expected.startsWith("TLS:")) {
                if(!(e instanceof SSLHandshakeException))throw e;
                String cause=expected.substring(4);boolean found=false;
                for(Throwable t=e;t!=null;t=t.getCause())if(t.toString().contains(cause))found=true;
                if(!found)throw e;
            } else if(!expected.equals(e.getMessage()))throw e;
            System.out.println("REJECT "+mode+" "+expected);
        } finally {
            if(!Arrays.equals(Files.readAllBytes(cache.resolve("text-state.enc")),new byte[]{7,8,9}))throw new AssertionError("phone state changed");
            Path dir=cache.resolve("android-update");
            if(Files.exists(dir.resolve("download.part"),LinkOption.NOFOLLOW_LINKS))throw new AssertionError("partial leak");
            if(!success && Files.exists(dir.resolve("verified.apk"),LinkOption.NOFOLLOW_LINKS))throw new AssertionError("failed ready leak");
            try(java.util.stream.Stream<Path> files=Files.walk(cache)){files.sorted(Comparator.reverseOrder()).forEach(p->{try{Files.delete(p);}catch(IOException e){throw new UncheckedIOException(e);}});}
        }
    }
}
