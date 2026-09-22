package org.paranoid.devnet;

import java.net.*;
import java.io.*;
import javax.net.ssl.HttpsURLConnection;
import org.json.*;

/** In-process RPC transport double: executes real DevnetRpc parsing and trust gate. */
public final class RpcProgramTest {
    static JSONObject p,d;
    static String genesis=DevnetRpc.GENESIS;
    static int pairedReads;
    static final class Connection extends HttpsURLConnection {
        final ByteArrayOutputStream request=new ByteArrayOutputStream();
        Connection(URL u){super(u);}
        public void connect(){} public void disconnect(){} public boolean usingProxy(){return false;}
        public String getCipherSuite(){return "fixture";}
        public java.security.cert.Certificate[] getLocalCertificates(){return null;}
        public java.security.cert.Certificate[] getServerCertificates(){return null;}
        public OutputStream getOutputStream(){return request;}
        public int getResponseCode(){return 200;}
        public InputStream getInputStream() throws IOException {
            try {
                JSONObject q=new JSONObject(new String(request.toByteArray(),"UTF-8"));
                String method=q.getString("method"); Object result;
                if(method.equals("getGenesisHash"))result=genesis;
                else if(method.equals("getAccountInfo"))result=new JSONObject().put("value",p);
                else if(method.equals("getMultipleAccounts")) {
                    JSONArray addresses=q.getJSONArray("params").getJSONArray(0);
                    if(!addresses.getString(0).equals(ProgramPinTest.pins.getString("program"))
                        ||!addresses.getString(1).equals(ProgramPinTest.pins.getString("programdata")))throw new AssertionError("wrong queried pins");
                    pairedReads++;result=new JSONObject().put("context",new JSONObject().put("slot",100)).put("value",new JSONArray().put(p).put(d));
                } else throw new AssertionError(method);
                return new ByteArrayInputStream(new JSONObject().put("jsonrpc","2.0").put("id",q.getLong("id")).put("result",result).toString().getBytes("UTF-8"));
            }catch(Exception e){throw new IOException(e);}
        }
    }
    public static void main(String[] args) throws Exception {
        ProgramPinTest.main(args);
        URL.setURLStreamHandlerFactory(protocol->"https".equals(protocol)?new URLStreamHandler(){
            protected URLConnection openConnection(URL u){return new Connection(u);}
            protected URLConnection openConnection(URL u,Proxy proxy){return new Connection(u);}
        }:null);
        p=ProgramPinTest.account(ProgramPinTest.programBytes,true);
        d=ProgramPinTest.account(ProgramPinTest.dataBytes,false);
        new DevnetRpc().program();
        byte[] bad=ProgramPinTest.dataBytes.clone();bad[13]^=1;d=ProgramPinTest.account(bad,false);
        boolean refused=false;try{new DevnetRpc().program();}catch(Exception expected){refused=true;}
        if(!refused)throw new AssertionError("RPC gate accepted wrong authority");
        if(pairedReads!=2)throw new AssertionError("missing same-context paired reads");
        d=ProgramPinTest.account(ProgramPinTest.dataBytes,false);genesis="wrong-network";
        refused=false;try{new DevnetRpc().program();}catch(Exception expected){refused=true;}
        if(!refused)throw new AssertionError("RPC gate accepted wrong genesis");
        System.out.println("RPC PROGRAM GATE PASS: shared native pins, paired finalized reads, authority and genesis refusal");
    }
}
