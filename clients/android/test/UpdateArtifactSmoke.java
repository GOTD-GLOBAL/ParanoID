package org.paranoid.text;
import java.nio.file.*;
import java.io.*;
public final class UpdateArtifactSmoke {
    public static void main(String[] a)throws Exception {
        UpdateManifest m=UpdateManifest.parse(Files.readAllBytes(Paths.get(a[0])));
        byte[][] signer={Files.readAllBytes(Paths.get(a[5]))},oldSigner={Files.readAllBytes(Paths.get(a[8]))};
        UpdatePolicy.verifyIdentity(m,a[2],Long.parseLong(a[3]),Integer.parseInt(a[4]),a[6],Long.parseLong(a[7]),signer,oldSigner,35,new String[]{"arm64-v8a"});
        UpdateClient.verifyBytes(new File(a[1]),m);
        if(UpdatePolicy.available(m,m.versionCode,35,new String[]{"arm64-v8a"}) || UpdatePolicy.available(m,m.versionCode+1,35,new String[]{"arm64-v8a"}))throw new AssertionError("same/lower must be no-update");
        Path bad=Files.createTempFile("update-corrupt-",".apk");
        try{
            byte[] bytes=Files.readAllBytes(Paths.get(a[1]));bytes[bytes.length/2]^=1;Files.write(bad,bytes);
            try{UpdateClient.verifyBytes(bad.toFile(),m);throw new AssertionError("changed APK accepted");}catch(IOException expected){}
            Files.write(bad,new byte[]{1});
            try{UpdateClient.verifyBytes(bad.toFile(),m);throw new AssertionError("truncated APK accepted");}catch(IOException expected){}
        }finally{Files.delete(bad);}
        System.out.println("Actual APK tools -> Java identity/hash policy PASS; same/lower no update; cached tamper/truncation rejected. Not Android PackageManager execution.");
    }
}
