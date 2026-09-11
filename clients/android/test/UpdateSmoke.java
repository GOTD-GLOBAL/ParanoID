package org.paranoid.text;
import java.nio.charset.StandardCharsets;
public final class UpdateSmoke {
    static final String JSON="{\"schema\":1,\"package\":\"global.paranoid.messenger\",\"version_code\":6,\"version_name\":\"0.0.6-update\",\"min_sdk\":26,\"abi\":\"arm64-v8a\",\"apk_sha256\":\""+repeat('a',64)+"\",\"apk_size\":3}";
    static String repeat(char c,int n){char[] b=new char[n];java.util.Arrays.fill(b,c);return new String(b);}
    public static void main(String[] args)throws Exception {
        Class<?> type;
        try{type=Class.forName("org.paranoid.text.UpdateManifest");}
        catch(ClassNotFoundException missing){throw new AssertionError("RFC0013 manifest parser missing",missing);}
        Object manifest=type.getMethod("parse",byte[].class).invoke(null,(Object)JSON.getBytes(StandardCharsets.UTF_8));
        if(type.getField("versionCode").getLong(manifest)!=6)throw new AssertionError("version parsed");
        System.out.println("UpdateSmoke valid manifest PASS");
    }
}
