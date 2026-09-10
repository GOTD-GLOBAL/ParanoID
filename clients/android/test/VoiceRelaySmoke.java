import org.paranoid.text.VoiceRelayConfig;
import java.nio.charset.StandardCharsets;
import java.util.Base64;

/** Strict issuer metadata and elapsed authority; real TLS/relay are separate gates. */
public final class VoiceRelaySmoke {
    static final long WALL=1800000000000L, MONO=5000000000L;
    static final long EXP=WALL/1000+1200;
    static final String REALM="https://127.0.0.1:38443";
    static final String USER=EXP+":0123456789abcdef0123456789abcdef";
    static final String PASS=Base64.getEncoder().encodeToString(new byte[20]);
    static final String GOOD="{\"v\":1,\"urls\":[\"turn:127.0.0.1:34781?transport=udp\",\"turn:127.0.0.1:34781?transport=tcp\"],\"username\":\""+USER+"\",\"credential\":\""+PASS+"\",\"expires\":"+EXP+",\"ttl\":1200}";
    interface Check {void run()throws Exception;}
    static int rejected;
    static void reject(Check task)throws Exception {try{task.run();}catch(java.io.IOException expected){rejected++;return;}throw new AssertionError("invalid issuer metadata accepted");}
    static VoiceRelayConfig parse(String text)throws Exception{return VoiceRelayConfig.parse(text.getBytes(StandardCharsets.UTF_8),REALM,WALL,MONO);}
    static VoiceRelayConfig at(long wall,long mono)throws Exception{return VoiceRelayConfig.parse(GOOD.getBytes(StandardCharsets.UTF_8),REALM,wall,mono);}
    public static void main(String[]args)throws Exception {
        VoiceRelayConfig c=parse(GOOD);
        if(c.urls().size()!=2||!c.username().equals(USER)||!c.password().equals(PASS))throw new AssertionError("valid config lost");
        if(!c.usable(WALL,MONO)||c.usable(WALL+201000,MONO+201000000000L))throw new AssertionError("authority deadline");
        if(c.usable(WALL,MONO+201000000000L)||c.usable(WALL,MONO-1))throw new AssertionError("clock rollback extended authority");
        if(c.toString().contains(USER)||c.toString().contains(PASS))throw new AssertionError("implicit secret disclosure");
        reject(()->parse(GOOD.replace("\"v\":1","\"v\":1,\"v\":1")));
        reject(()->parse(GOOD.replace("\"v\":1","\"v\":1,\"extra\":0")));
        reject(()->parse(GOOD.replace("\"v\":1","\"v\":1.0")));
        reject(()->parse(GOOD.replace("\"v\":1","\"v\":true")));
        reject(()->parse(GOOD.replace("\"ttl\":1200","\"ttl\":1201")));
        reject(()->parse(GOOD.replace("turn:127.0.0.1:34781?transport=udp","turn:192.0.2.1:34781?transport=udp")));
        reject(()->parse(GOOD.replace(":34781?transport=tcp",":34782?transport=tcp")));
        reject(()->parse(GOOD.replace("turn:","stun:")));
        reject(()->parse(GOOD.replace(USER,"0"+USER)));
        reject(()->parse(GOOD.replace(USER,(EXP-1)+":0123456789abcdef0123456789abcdef")));
        reject(()->parse(GOOD.replace(PASS,PASS.substring(0,PASS.length()-1))));
        reject(()->parse(GOOD.replace("\"expires\":"+EXP,"\"expires\":9223372036854775808")));
        reject(()->parse(GOOD+"x"));
        reject(()->VoiceRelayConfig.parse(GOOD.getBytes(StandardCharsets.UTF_8),"https://localhost:38443",WALL,MONO));
        reject(()->VoiceRelayConfig.parse(GOOD.getBytes(StandardCharsets.UTF_8),REALM,WALL+201000,MONO));
        reject(()->VoiceRelayConfig.parse(GOOD.getBytes(StandardCharsets.UTF_8),REALM,WALL-6000,MONO));
        reject(()->VoiceRelayConfig.parse(new byte[]{(byte)0xff},REALM,WALL,MONO));
        reject(()->VoiceRelayConfig.parse(new byte[2049],REALM,WALL,MONO));
        // JSON ambiguities must not be normalized differently by the host and Android.
        reject(()->parse(GOOD.replace("\"v\":1","\"v\":1,\"\\u0076\":1")));
        reject(()->parse(GOOD.replace("\"v\":1,","")));
        reject(()->parse(GOOD.replace("\"v\":1","\"v\":01")));
        reject(()->parse(GOOD.replace("\"v\":1","\"v\":1e0")));
        reject(()->parse(GOOD.replace("\"v\":1","\"v\":-0")));
        reject(()->parse(GOOD.replace("\"v\":1","\"v\":null")));
        reject(()->parse(GOOD.replace("\"urls\":[","\"urls\":[0,")));
        reject(()->parse(GOOD.replace("?transport=tcp","?transport=udp")));
        reject(()->parse(GOOD.replace("?transport=udp\",","?transport=udp\",\"extra\",")));
        reject(()->parse(GOOD.replace("?transport=udp","?transport=udp&x=y")));
        reject(()->parse(GOOD.replace("\"username\":\"","\"username\":\"\\uD800")));
        reject(()->parse(GOOD.replace("\"username\":\"","\"username\":\"\\uDC00")));
        reject(()->parse(GOOD.replace("\"username\":\"","\"username\":\"\\x")));
        reject(()->parse(GOOD.replace(USER,USER.toUpperCase(java.util.Locale.ROOT))));
        reject(()->parse(GOOD.replace(PASS,PASS.substring(0,26)+"B=")));
        reject(()->VoiceRelayConfig.parse(new byte[]{(byte)0xc0,(byte)0xaf},REALM,WALL,MONO));
        reject(()->VoiceRelayConfig.parse(null,REALM,WALL,MONO));
        // Retained origins cannot smuggle a different TURN host or a DNS lookup.
        for(String realm:new String[]{"http://127.0.0.1:38443","https://127.000.0.1:38443",
                "https://127.1:38443","https://user@127.0.0.1:38443","https://127.0.0.1:38443/path",
                "https://127.0.0.1:38443?x=1","https://127.0.0.1:38443#fragment","https://[::1]:38443",
                "https://127.0.0.1:65536","https://127.0.0.1:0","https://127.0.0.1:038443"}) {
            reject(()->VoiceRelayConfig.parse(GOOD.getBytes(StandardCharsets.UTF_8),realm,WALL,MONO));
        }
        // Millisecond and nanosecond boundaries keep delayed SDK creation conservative.
        if(!at(WALL+200000,MONO).usable(WALL+200000,MONO)
                ||!at(WALL-5000,MONO).usable(WALL-5000,MONO))throw new AssertionError("inclusive receipt bounds");
        reject(()->at(WALL+200001,MONO));
        reject(()->at(WALL-5001,MONO));
        if(!c.usable(WALL+200000,MONO+200000000000L)
                ||c.usable(WALL,MONO+200000000001L)
                ||c.usable(WALL+200001,MONO)
                ||c.usable(Long.MIN_VALUE,MONO)
                ||c.usable(WALL,Long.MIN_VALUE))throw new AssertionError("precise expiry or clock overflow");
        reject(()->parse(GOOD.replace(Long.toString(EXP),Long.toString(Long.MAX_VALUE))));
        try {c.urls().set(0,"turn:example.test:34781?transport=udp");throw new AssertionError("mutable relay URLs");}
        catch(UnsupportedOperationException expected) { }
        // Legal JSON escaping/whitespace and either canonical HTTPS port form remain portable.
        if(!parse(" \n"+GOOD.replace("\"v\"","\"\\u0076\"").replace("turn:","\\u0074urn:")+"\r\t").usable(WALL,MONO))throw new AssertionError("legal JSON");
        VoiceRelayConfig.parse(GOOD.getBytes(StandardCharsets.UTF_8),"https://127.0.0.1",WALL,MONO);
        if(!at(WALL,-1000000000L).usable(WALL,-1000000000L))throw new AssertionError("nanoTime origin may be negative");
        System.out.println("Voice relay config PASS: valid issuer + "+rejected+" strict negatives + independent wall/monotonic deadline");
    }
}
