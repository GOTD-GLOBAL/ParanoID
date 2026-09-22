package org.paranoid.devnet;
/** Pure worker error boundary: never load a wallet or transmit a transaction. */
public final class DevnetWorkTest {
    public static void main(String[] args)throws Exception {
        if(!"ok".equals(DevnetWork.run(()->"ok")))throw new AssertionError("successful result");
        for(LinkageError error:new LinkageError[]{new UnsatisfiedLinkError("private detail"),new ExceptionInInitializerError("private detail"),new NoClassDefFoundError("private detail")}) {
            String result=DevnetWork.run(()->{throw error;});
            if(!result.contains("Devnet")||result.contains("private detail"))throw new AssertionError("unsafe error reporting");
        }
        String frozen=DevnetWork.run(()->{throw new java.io.IOException("storage_frozen");});
        if(!frozen.contains("Не очищайте данные")||!frozen.contains("ID")||!frozen.contains("сброса"))throw new AssertionError("frozen store must explain messenger data risk and missing safe reset");
        System.out.println("DEVNET WORK BOUNDARY PASS");
    }
}
