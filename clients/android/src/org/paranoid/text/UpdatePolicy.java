package org.paranoid.text;

import java.io.*;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.Arrays;

/** Pure policy shared by the Android PackageManager/provider adapters and JVM tests. */
public final class UpdatePolicy {
    public static final String URI="content://org.paranoid.devtext.updates/verified.apk";
    private UpdatePolicy(){}
    public static boolean available(UpdateManifest m,long installed,int sdk,String[] abis)throws IOException {
        if(m.versionCode<=installed)return false;
        if(m.minSdk>sdk || !Arrays.asList(abis).contains("arm64-v8a"))throw new IOException("incompatible device");
        return true;
    }
    public static void verifyIdentity(UpdateManifest m,String pkg,long version,int minSdk,String installedPkg,long installedVersion,
        byte[][] apkSigners,byte[][] installedSigners,int sdk,String[] abis)throws IOException {
        if(!"org.paranoid.devtext".equals(pkg) || !pkg.equals(installedPkg) || version!=m.versionCode || minSdk!=m.minSdk
            || !available(m,installedVersion,sdk,abis))throw new IOException("APK identity/version mismatch");
        if(apkSigners==null || installedSigners==null || apkSigners.length!=1 || installedSigners.length!=1
            || apkSigners[0]==null || installedSigners[0]==null || apkSigners[0].length==0
            || !MessageDigest.isEqual(apkSigners[0],installedSigners[0]))throw new IOException("APK signer mismatch");
    }
    public static File directory(File cache)throws IOException {
        File base=cache.getCanonicalFile(),dir=new File(base,"android-update");
        if(Files.isSymbolicLink(cache.toPath()) || !dir.getCanonicalFile().equals(dir)
            || !Files.isDirectory(dir.toPath(),LinkOption.NOFOLLOW_LINKS))throw new IOException("private update directory required");
        return dir;
    }
    public static File providerFile(File cache,String uri,String mode)throws IOException {
        if(!URI.equals(uri) || !"r".equals(mode))throw new IOException("update URI is read only");
        File apk=new File(directory(cache),"verified.apk");
        if(!Files.isRegularFile(apk.toPath(),LinkOption.NOFOLLOW_LINKS) || apk.length()<1 || apk.length()>UpdateManifest.MAX_APK
            || !apk.getCanonicalFile().equals(apk))throw new IOException("verified APK unavailable");
        return apk;
    }
}
