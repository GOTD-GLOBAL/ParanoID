import org.paranoid.text.SyncCycle;
import com.sun.net.httpserver.HttpServer;
import java.net.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;

/** Real local HTTP rejection fixtures; not Android storage or a hosted deployment. */
public final class SyncSmoke {
    private static void rejectedSendStillReceives(int status) throws Exception {
        HttpServer server=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);
        AtomicInteger gets=new AtomicInteger(),posts=new AtomicInteger();
        List<byte[]> requests=Collections.synchronizedList(new ArrayList<>());
        server.createContext("/send",e->{
            ByteArrayOutputStream bytes=new ByteArrayOutputStream();byte[] buf=new byte[64];int n;
            try(InputStream in=e.getRequestBody()){while((n=in.read(buf))!=-1)bytes.write(buf,0,n);}
            requests.add(bytes.toByteArray());posts.incrementAndGet();e.sendResponseHeaders(status,-1);e.close();
        });
        server.createContext("/receive",e->{gets.incrementAndGet();byte[] bytes="inbound fixture".getBytes("UTF-8");e.sendResponseHeaders(200,bytes.length);try(OutputStream out=e.getResponseBody()){out.write(bytes);}});
        server.start();
        byte[] pending=new byte[]{1,2,3,4};byte[] original=pending.clone();
        try {
            String base="http://127.0.0.1:"+server.getAddress().getPort();
            boolean failed=false;
            try {SyncCycle.run(()->{
                HttpURLConnection c=(HttpURLConnection)new URL(base+"/send").openConnection();
                c.setConnectTimeout(2000);c.setReadTimeout(2000);c.setRequestMethod("POST");c.setDoOutput(true);
                try {try(OutputStream out=c.getOutputStream()){out.write(pending);}if(c.getResponseCode()!=200)throw new IOException("HTTP rejection");}
                finally{c.disconnect();}
            },()->{
                HttpURLConnection c=(HttpURLConnection)new URL(base+"/receive").openConnection();c.setConnectTimeout(2000);c.setReadTimeout(2000);
                try{if(c.getResponseCode()!=200)throw new IOException("receive failed");try(InputStream in=c.getInputStream()){while(in.read()!=-1){}}}finally{c.disconnect();}
            },()->false);}catch(IOException expected){failed=true;}
            if(!failed)throw new AssertionError("outbound failure hidden");
            if(gets.get()!=1)throw new AssertionError("HTTP "+status+" blocked inbound GET");
            if(posts.get()!=2)throw new AssertionError("post-receive outbound phase missing");
            if(!Arrays.equals(pending,original))throw new AssertionError("pending bytes changed");
            for(byte[] body:requests)if(!Arrays.equals(body,original))throw new AssertionError("retry bytes changed");
        }finally{server.stop(0);}
    }
    private static void storageFailureStopsEverything()throws Exception {
        List<String> trace=new ArrayList<>();boolean[] frozen={false};
        try {SyncCycle.run(()->{trace.add("send");frozen[0]=true;throw new IOException("ambiguous local commit");},()->trace.add("receive"),()->frozen[0]);throw new AssertionError("failure hidden");}
        catch(IOException expected){}
        if(!trace.equals(Arrays.asList("send")))throw new AssertionError("continued after local failure");
        trace.clear();
        try {SyncCycle.run(()->trace.add("send"),()->trace.add("receive"),()->true);throw new AssertionError("frozen state accepted");}
        catch(IOException expected){}
        if(!trace.isEmpty())throw new AssertionError("network on frozen state");
    }
    private static void rejectedItemDoesNotStarveLaterReceipt()throws Exception {
        for(int code:new int[]{409,507}) {
            List<String> trace=new ArrayList<>();
            try {SyncCycle.drain(Arrays.asList("blocked","receipt"),item->{
                trace.add(item);if(item.equals("blocked"))throw new SyncCycle.Rejected(code);
            },()->false);throw new AssertionError("blocked item hidden");}catch(SyncCycle.Rejected expected){if(expected.status!=code)throw expected;}
            if(!trace.equals(Arrays.asList("blocked","receipt")))throw new AssertionError("later receipt starved behind HTTP "+code);
        }
        List<String> trace=new ArrayList<>();boolean[] frozen={false};
        try {SyncCycle.drain(Arrays.asList("first","never"),item->{trace.add(item);frozen[0]=true;throw new IOException("local commit failed");},()->frozen[0]);throw new AssertionError("local failure hidden");}catch(IOException expected){}
        if(!trace.equals(Arrays.asList("first")))throw new AssertionError("batch continued after local failure");
        trace.clear();
        try {SyncCycle.drain(Arrays.asList("auth","never"),item->{trace.add(item);throw new SyncCycle.Rejected(401);},()->false);throw new AssertionError("auth failure hidden");}catch(SyncCycle.Rejected expected){}
        if(!trace.equals(Arrays.asList("auth")))throw new AssertionError("batch continued after auth failure");
    }
    private static void cancellationAndInboundFailureAreNotSwallowed()throws Exception {
        List<String> trace=new ArrayList<>();
        try {SyncCycle.run(()->trace.add("send"),()->{trace.add("receive");throw new IOException("receive failed");},()->false);throw new AssertionError("inbound failure hidden");}catch(IOException expected){}
        if(!trace.equals(Arrays.asList("send","receive")))throw new AssertionError("continued after inbound failure");
        trace.clear();Thread.currentThread().interrupt();
        try {SyncCycle.run(()->trace.add("send"),()->trace.add("receive"),()->false);throw new AssertionError("cancellation ignored");}catch(InterruptedException expected){}finally{Thread.interrupted();}
        if(!trace.isEmpty())throw new AssertionError("network after interruption");
        AtomicInteger attempts=new AtomicInteger(),received=new AtomicInteger();
        SyncCycle.run(()->{if(attempts.incrementAndGet()==1)throw new IOException("transient send failure");},()->received.incrementAndGet(),()->false);
        if(attempts.get()!=2 || received.get()!=1)throw new AssertionError("transient recovery failed");
    }
    public static void main(String[] args)throws Exception {
        rejectedSendStillReceives(409);rejectedSendStillReceives(507);storageFailureStopsEverything();rejectedItemDoesNotStarveLaterReceipt();cancellationAndInboundFailureAreNotSwallowed();
        System.out.println("Sync cycle: PASS (real HTTP409/507 do not block GET; exact retry bytes; local failures stop)");
    }
}
