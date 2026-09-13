package org.paranoid.text;
import java.io.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
public final class UpdateLargeSmoke {
    public static void main(String[] args)throws Exception {
        for(long size:new long[]{16777216L,16777217L,2147483648L,Long.MAX_VALUE}) {
            UpdateManifest m=UpdateManifest.parse(UpdateSmoke.JSON.replace("\"apk_size\":3","\"apk_size\":"+size).getBytes(StandardCharsets.UTF_8));
            if(m.apkSize!=size)throw new AssertionError("size truncated");
        }
        Path cache=Files.createTempDirectory("large-update-provider-");
        Path dir=Files.createDirectory(cache.resolve("android-update"));
        Path apk=dir.resolve("verified.apk");
        try {
            try(RandomAccessFile f=new RandomAccessFile(apk.toFile(),"rw")){f.setLength(2147483648L);}
            if(!UpdatePolicy.providerFile(cache.toFile(),UpdatePolicy.URI,"r").equals(apk.toFile()))throw new AssertionError("large provider file");
        }finally{Files.deleteIfExists(apk);Files.delete(dir);Files.delete(cache);}
        System.out.println("UpdateLargeSmoke PASS (manifest signed-long range and sparse 2GiB provider fixture, not install evidence)");
    }
}
