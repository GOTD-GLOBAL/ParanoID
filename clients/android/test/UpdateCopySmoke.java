package org.paranoid.text;
import java.lang.reflect.*;
import java.io.*;
public final class UpdateCopySmoke {
    public static void main(String[] args)throws Exception {
        Method check=UpdateClient.class.getDeclaredMethod("checkedTotal",long.class,int.class,long.class);
        check.setAccessible(true);
        if((Long)check.invoke(null,Long.MAX_VALUE-1,1,Long.MAX_VALUE)!=Long.MAX_VALUE)throw new AssertionError("exact long boundary");
        for(long[] c:new long[][]{{Long.MAX_VALUE-1,2,Long.MAX_VALUE},{3,1,3},{0,8192,8191}}) {
            try{check.invoke(null,c[0],(int)c[1],c[2]);throw new AssertionError("overshoot accepted");}
            catch(InvocationTargetException e){if(!(e.getCause() instanceof IOException))throw e;}
        }
        if(args.length>0 && args[0].equals("nofollow")) {
            java.nio.file.Path dir=java.nio.file.Files.createTempDirectory("cached-link-"),file=dir.resolve("real"),link=dir.resolve("link");
            try {
                java.nio.file.Files.write(file,new byte[4]);java.nio.file.Files.createSymbolicLink(link,file);
                UpdateManifest m=UpdateManifest.parse(UpdateSmoke.JSON.getBytes(java.nio.charset.StandardCharsets.UTF_8));
                try{UpdateClient.verifyBytes(link.toFile(),m);throw new AssertionError("cached link accepted");}
                catch(IOException expected){if(!expected.getMessage().contains("NOFOLLOW_LINKS"))throw expected;} // Must fail at open, not after reading/hash.
            }finally{java.nio.file.Files.deleteIfExists(link);java.nio.file.Files.deleteIfExists(file);java.nio.file.Files.delete(dir);}
            System.out.println("UpdateCopySmoke cached no-follow PASS");return;
        }
        if(args.length>0 && args[0].equals("cached")) {
            java.nio.file.Path file=java.nio.file.Files.createTempFile("cached-update-",".bin");
            try {
                java.nio.file.Files.write(file,new byte[65536]);
                UpdateManifest m=UpdateManifest.parse(UpdateSmoke.JSON.getBytes(java.nio.charset.StandardCharsets.UTF_8));
                try{UpdateClient.verifyBytes(file.toFile(),m);throw new AssertionError("cached overshoot accepted");}
                catch(IOException e){if(!e.getMessage().equals("size exceeded declared 3"))throw new AssertionError("cached verification not declared-bounded",e);}
            }finally{java.nio.file.Files.delete(file);}
            System.out.println("UpdateCopySmoke cached bound PASS");return;
        }
        Method copy=UpdateClient.class.getDeclaredMethod("copy",InputStream.class,OutputStream.class,int.class,java.security.MessageDigest.class,long.class,long.class);
        copy.setAccessible(true);
        ByteArrayOutputStream out=new ByteArrayOutputStream();
        try{copy.invoke(null,new ByteArrayInputStream(new byte[9]),out,8,null,System.nanoTime(),8L);throw new AssertionError("copy overshoot accepted");}
        catch(InvocationTargetException e){if(!(e.getCause() instanceof IOException))throw e;}
        if(out.size()!=8)throw new AssertionError("offending bytes written before limit check: "+out.size());
        if(args.length>0){System.out.println("UpdateCopySmoke before-write PASS");return;}
        main(new String[]{"cached"});
        main(new String[]{"nofollow"});
        System.out.println("UpdateCopySmoke PASS (overflow-safe, before-write and cached declared-size bounds)");
    }
}
