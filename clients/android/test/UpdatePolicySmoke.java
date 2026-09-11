package org.paranoid.text;
import java.io.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.lang.reflect.*;
public final class UpdatePolicySmoke {
    interface Task{void run()throws Exception;}
    static int rejects;
    static void reject(Task t)throws Exception {try{t.run();}catch(Exception expected){rejects++;return;}throw new AssertionError("unsafe update accepted");}
    public static void main(String[] args)throws Exception {
        String j=UpdateSmoke.JSON;
        for(String bad:new String[]{j+"{}",j.replace("\"schema\":1","\"schema\":1,\"schema\":1"),j.replace("\"schema\":1","\"schema\":1,\"x\":1"),j.replace("\"schema\":1","\"schema\":1.0"),j.replace("\"schema\":1","\"schema\":\"1\""),j.replace("\"schema\":1","'schema':1"),j.replace(":6",":06"),j.replace(":6",":-1"),j.replace(":6",":9223372036854775808"),j.replace("global.paranoid.messenger","other.package"),j.replace("arm64-v8a","x86"),j.replace("\"apk_size\":3","\"apk_size\":16777217"),j.replace("\"apk_size\":3","\"apk_size\":0"),j.replace(UpdateSmoke.repeat('a',64),"../escape"),j.replace("0.0.6-update",UpdateSmoke.repeat('x',129)),j.replace("0.0.6-update","bad\\u0000name"),j.replace("0.0.6-update","bad\\ud800name"),j.replace("}",",}")})reject(()->UpdateManifest.parse(bad.getBytes(StandardCharsets.UTF_8)));
        reject(()->UpdateManifest.parse(j.replace("schema","s\\u００６３hema").getBytes(StandardCharsets.UTF_8)));
        reject(()->UpdateManifest.parse(new byte[]{(byte)0xc3,0x28}));reject(()->UpdateManifest.parse(new byte[8193]));
        Class<?> policy;try{policy=Class.forName("org.paranoid.text.UpdatePolicy");}catch(ClassNotFoundException e){throw new AssertionError("APK identity and provider policy missing",e);}
        Method identity=policy.getMethod("verifyIdentity",UpdateManifest.class,String.class,long.class,int.class,String.class,long.class,byte[][].class,byte[][].class,int.class,String[].class);
        UpdateManifest m=UpdateManifest.parse(j.getBytes(StandardCharsets.UTF_8));byte[][] sign={{1,2,3}};
        Object[] ok={m,"global.paranoid.messenger",6L,26,"global.paranoid.messenger",5L,sign,sign,35,new String[]{"arm64-v8a"}};
        identity.invoke(null,ok);
        for(int field:new int[]{1,2,3,4,5,6,7,8,9}){Object[] bad=ok.clone();switch(field){case 1:case 4:bad[field]="evil.package";break;case 2:bad[field]=7L;break;case 3:bad[field]=27;break;case 5:bad[field]=6L;break;case 6:bad[field]=new byte[][]{{9}};break;case 7:bad[field]=new byte[][]{{1,2,3},{4}};break;case 8:bad[field]=25;break;case 9:bad[field]=new String[]{"x86"};break;}reject(()->identity.invoke(null,bad));}
        Method file=policy.getMethod("providerFile",File.class,String.class,String.class);
        Path cache=Files.createTempDirectory("update-provider-");Path dir=Files.createDirectory(cache.resolve("android-update"));Path apk=Files.write(dir.resolve("verified.apk"),new byte[]{1});
        String uri="content://global.paranoid.messenger.updates/verified.apk";
        if(!file.invoke(null,cache.toFile(),uri,"r").equals(apk.toFile()))throw new AssertionError("fixed APK");
        for(String bad:new String[]{uri+"?x=1",uri+"#f",uri+"/../text-state.enc",uri.replace("verified.apk","%76erified.apk"),uri.replace(".updates",".files"),"file://"+apk})reject(()->file.invoke(null,cache.toFile(),bad,"r"));
        for(String mode:new String[]{"w","rw","rwt","wa"})reject(()->file.invoke(null,cache.toFile(),uri,mode));
        Files.delete(apk);Files.createSymbolicLink(apk,cache.resolve("text-state.enc"));reject(()->file.invoke(null,cache.toFile(),uri,"r"));Files.delete(apk);Files.delete(dir);Files.delete(cache);
        System.out.println("UpdatePolicySmoke PASS; negative cases="+rejects);
    }
}
