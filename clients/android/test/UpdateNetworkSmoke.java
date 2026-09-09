package org.paranoid.text;
import java.io.*;
import java.lang.reflect.*;
import java.nio.file.*;
public final class UpdateNetworkSmoke {
    public static void main(String[] args)throws Exception {
        Class<?> c;try{c=Class.forName("org.paranoid.text.UpdateClient");}catch(ClassNotFoundException e){throw new AssertionError("pinned update download missing",e);}
        if(args[2].equals("cookie"))java.net.CookieHandler.setDefault(new java.net.CookieManager());
        Object client=c.getConstructor(String.class,String.class).newInstance(args[0],args[1]);
        Object m=c.getMethod("check").invoke(client);
        if(args[2].equals("absent")){if(m!=null)throw new AssertionError("404 must be absent");System.out.println("absent PASS");return;}
        if(m==null)throw new AssertionError("missing manifest");
        Path cache=Files.createTempDirectory("update-download-");
        Files.write(cache.resolve("text-state.enc"),new byte[]{7,8,9});
        try {
            Class<?> verifier=Class.forName("org.paranoid.text.UpdateClient$Verifier");
            Object gate=Proxy.newProxyInstance(c.getClassLoader(),new Class<?>[]{verifier},(p,method,a)->{if(args[2].equals("reject-apk"))throw new IOException("APK rejected");if(((File)a[0]).getName().equals("verified.apk"))throw new AssertionError("promotion before verification");return null;});
            File apk=(File)c.getMethod("download",UpdateManifest.class,File.class,verifier).invoke(client,m,cache.toFile(),gate);
            if(!apk.getName().equals("verified.apk") || apk.length()!=((UpdateManifest)m).apkSize)throw new AssertionError("verified cache");
            System.out.println("download PASS "+apk.length());
        } finally {
            if(!java.util.Arrays.equals(Files.readAllBytes(cache.resolve("text-state.enc")),new byte[]{7,8,9}))throw new AssertionError("phone state changed");
            Path temp=cache.resolve("android-update/download.part");if(Files.exists(temp))throw new AssertionError("partial leak");
            try(java.util.stream.Stream<Path> files=Files.walk(cache)){files.sorted(java.util.Comparator.reverseOrder()).forEach(p->{try{Files.delete(p);}catch(IOException e){throw new RuntimeException(e);}});}
        }
    }
}
