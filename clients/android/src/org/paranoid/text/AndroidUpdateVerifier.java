package org.paranoid.text;

import android.content.Context;
import android.content.pm.*;
import android.os.Build;
import java.io.*;

/** The device PackageManager parses and verifies the real archive, not feed assertions. */
public final class AndroidUpdateVerifier {
    private AndroidUpdateVerifier(){}
    static int flags(){return Build.VERSION.SDK_INT>=28?PackageManager.GET_SIGNING_CERTIFICATES:PackageManager.GET_SIGNATURES;}
    static long version(PackageInfo info){return Build.VERSION.SDK_INT>=28?info.getLongVersionCode():info.versionCode;}
    static byte[][] signers(PackageInfo info)throws IOException {
        Signature[] signatures;
        if(Build.VERSION.SDK_INT>=28){
            if(info.signingInfo==null || info.signingInfo.hasMultipleSigners())throw new IOException("unsupported signers");
            Signature[] history=info.signingInfo.getSigningCertificateHistory();
            if(history==null || history.length!=1)throw new IOException("signer rotation unsupported");
            signatures=info.signingInfo.getApkContentsSigners();
        }else signatures=info.signatures;
        if(signatures==null || signatures.length!=1 || signatures[0]==null)throw new IOException("one signer required");
        return new byte[][]{signatures[0].toByteArray()};
    }
    static PackageInfo installed(Context context)throws Exception{return context.getPackageManager().getPackageInfo(context.getPackageName(),flags());}
    public static void verify(Context context,File apk,UpdateManifest manifest)throws Exception {
        PackageInfo actual=context.getPackageManager().getPackageArchiveInfo(apk.getAbsolutePath(),flags());
        PackageInfo current=installed(context);
        if(actual==null || actual.applicationInfo==null)throw new IOException("unreadable APK");
        UpdatePolicy.verifyIdentity(manifest,actual.packageName,version(actual),actual.applicationInfo.minSdkVersion,
            current.packageName,version(current),signers(actual),signers(current),Build.VERSION.SDK_INT,Build.SUPPORTED_ABIS);
        // Check actual native payload too; metadata's ABI cannot authorize arbitrary native code layout.
        boolean nativeCore=false;
        try(java.util.zip.ZipFile zip=new java.util.zip.ZipFile(apk)){
            java.util.Enumeration<? extends java.util.zip.ZipEntry> entries=zip.entries();
            while(entries.hasMoreElements()){
                String name=entries.nextElement().getName();
                if(name.startsWith("lib/") && !name.startsWith("lib/arm64-v8a/"))throw new IOException("unsupported APK ABI");
                if(name.equals("lib/arm64-v8a/libparanoid_client_core.so"))nativeCore=true;
            }
        }
        if(!nativeCore)throw new IOException("ARM64 core missing");
    }
}
