package org.paranoid.text;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** RFC0013's small flat JSON grammar: identical on Android and the host JVM. */
public final class UpdateManifest {
    public final long versionCode, apkSize;
    public final int minSdk;
    public final String versionName, sha256;
    private UpdateManifest(Map<String,Object> m)throws IOException {
        if(m.size()!=8 || number(m,"schema")!=1 || !"global.paranoid.messenger".equals(m.get("package"))
            || !"arm64-v8a".equals(m.get("abi")))throw new IOException("metadata schema");
        versionCode=number(m,"version_code");apkSize=number(m,"apk_size");
        long sdk=number(m,"min_sdk");if(sdk>Integer.MAX_VALUE)throw new IOException("SDK range");minSdk=(int)sdk;
        versionName=string(m,"version_name");sha256=string(m,"apk_sha256");
        if(versionName.isEmpty() || versionName.getBytes(StandardCharsets.UTF_8).length>128
            || !sha256.matches("[0-9a-f]{64}"))throw new IOException("metadata bounds");
        for(int i=0;i<versionName.length();i++)if(Character.isISOControl(versionName.charAt(i)))throw new IOException("version text");
    }
    private static long number(Map<String,Object> m,String k)throws IOException {
        Object v=m.get(k);if(!(v instanceof Long) || (Long)v<=0)throw new IOException("positive integer required");return (Long)v;
    }
    private static String string(Map<String,Object> m,String k)throws IOException {
        Object v=m.get(k);if(!(v instanceof String))throw new IOException("string required");return (String)v;
    }
    public static UpdateManifest parse(byte[] bytes)throws Exception {
        if(bytes.length==0 || bytes.length>8192)throw new IOException("metadata size");
        String text=StandardCharsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes)).toString();
        return new UpdateManifest(new Parser(text).object());
    }
    private static final class Parser {
        final String s;int p;
        Parser(String s){this.s=s;}
        void space(){while(p<s.length() && " \r\n\t".indexOf(s.charAt(p))>=0)p++;}
        char take()throws IOException {if(p>=s.length())throw new IOException("truncated JSON");return s.charAt(p++);}
        void expect(char c)throws IOException {space();if(take()!=c)throw new IOException("JSON syntax");}
        String text()throws IOException {
            expect('"');StringBuilder b=new StringBuilder();
            while(true){char c=take();if(c=='"')break;if(c<32)throw new IOException("JSON control");
                if(c=='\\'){c=take();switch(c){
                    case '"':case '\\':case '/':break;
                    case 'b':c='\b';break;case 'f':c='\f';break;case 'n':c='\n';break;case 'r':c='\r';break;case 't':c='\t';break;
                    case 'u':int n=0;for(int i=0;i<4;i++){char h=take();int d="0123456789abcdef".indexOf(h>='A' && h<='F'?(char)(h+32):h);if(d<0)throw new IOException("JSON escape");n=n*16+d;}c=(char)n;break;
                    default:throw new IOException("JSON escape");}}
                b.append(c);
            }
            String value=b.toString();for(int i=0;i<value.length();i++){
                char c=value.charAt(i);if(Character.isHighSurrogate(c)){if(++i>=value.length() || !Character.isLowSurrogate(value.charAt(i)))throw new IOException("surrogate");}
                else if(Character.isLowSurrogate(c))throw new IOException("surrogate");
            }return value;
        }
        Map<String,Object> object()throws IOException {
            Map<String,Object> m=new HashMap<>();expect('{');
            while(true){String key=text();expect(':');space();Object value;
                if(p<s.length() && s.charAt(p)=='"')value=text();
                else {int start=p;while(p<s.length() && s.charAt(p)>='0' && s.charAt(p)<='9')p++;
                    String n=s.substring(start,p);if(!n.matches("0|[1-9][0-9]*"))throw new IOException("JSON integer");
                    try{value=Long.valueOf(n);}catch(NumberFormatException bad){throw new IOException("integer overflow");}}
                if(m.put(key,value)!=null || m.size()>8)throw new IOException("duplicate/extra field");
                space();char next=take();if(next=='}')break;if(next!=',')throw new IOException("JSON separator");
            }
            space();if(p!=s.length())throw new IOException("JSON trailing input");return m;
        }
    }
}
