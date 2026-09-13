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
        System.out.println("UpdateCopySmoke PASS (overflow-safe declared-size accounting)");
    }
}
