package org.paranoid.devnet;

import java.nio.file.*;
import java.util.*;
import org.json.*;

/** Synthetic RPC fixtures around the actual built SBF, not live-chain evidence. */
public final class ProgramPinTest {
    static JSONObject pins;
    static byte[] programBytes, dataBytes;
    static JSONObject account(byte[] bytes, boolean executable) throws Exception {
        return new JSONObject().put("owner",pins.getString("loader")).put("executable",executable)
            .put("data",new JSONArray().put(Base64.getEncoder().encodeToString(bytes)).put("base64"));
    }
    static void rejected(String label, JSONObject p, JSONObject d) throws Exception {
        try { ProgramPin.verify(pins,p,d); }
        catch(Exception expected) { System.out.println("reject "+label); return; }
        throw new AssertionError("accepted "+label);
    }
    public static void main(String[] args) throws Exception {
        pins=SolanaBridge.run(new JSONObject().put("op","program_info"));
        byte[] sbf=Files.readAllBytes(Paths.get(args[0]));
        programBytes=new byte[36];programBytes[0]=2;
        System.arraycopy(Base64.getDecoder().decode(pins.getString("programdata_bytes")),0,programBytes,4,32);
        dataBytes=new byte[45+sbf.length];dataBytes[0]=3;dataBytes[12]=1;
        System.arraycopy(Base64.getDecoder().decode(pins.getString("authority_bytes")),0,dataBytes,13,32);
        System.arraycopy(sbf,0,dataBytes,45,sbf.length);
        ProgramPin.verify(pins,account(programBytes,true),account(dataBytes,false));
        byte[] bad=dataBytes.clone();bad[13]^=1;
        rejected("wrong upgrade authority",account(programBytes,true),account(bad,false));
        bad=dataBytes.clone();bad[bad.length-1]^=1;
        rejected("modified bytecode",account(programBytes,true),account(bad,false));
        rejected("missing program",null,account(dataBytes,false));
        rejected("missing programdata",account(programBytes,true),null);
        rejected("program not executable",account(programBytes,false),account(dataBytes,false));
        rejected("executable programdata",account(programBytes,true),account(dataBytes,true));
        rejected("wrong loader",account(programBytes,true).put("owner","11111111111111111111111111111111"),account(dataBytes,false));
        rejected("wrong programdata owner",account(programBytes,true),account(dataBytes,false).put("owner","11111111111111111111111111111111"));
        for(int offset:new int[]{0,1,4}){bad=programBytes.clone();bad[offset]^=1;rejected("program tag/link "+offset,account(bad,true),account(dataBytes,false));}
        for(int offset:new int[]{0,1,12}){bad=dataBytes.clone();bad[offset]^=1;rejected("programdata tag/authority option "+offset,account(programBytes,true),account(bad,false));}
        rejected("short program",account(Arrays.copyOf(programBytes,35),true),account(dataBytes,false));
        rejected("short programdata",account(programBytes,true),account(Arrays.copyOf(dataBytes,44),false));
        rejected("extra programdata bytes",account(programBytes,true),account(Arrays.copyOf(dataBytes,dataBytes.length+1),false));
        rejected("wrong encoding",account(programBytes,true).put("data",new JSONArray().put("AA==").put("base64+zstd")),account(dataBytes,false));
        rejected("invalid base64",account(programBytes,true).put("data",new JSONArray().put("!").put("base64")),account(dataBytes,false));
        System.out.println("PROGRAM PIN PASS");
    }
}
