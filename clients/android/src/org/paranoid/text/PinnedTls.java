package org.paranoid.text;

import javax.net.ssl.*;
import java.io.IOException;
import java.net.InetAddress;
import java.net.Socket;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.cert.CertificateException;
import java.security.cert.X509Certificate;
import java.security.interfaces.ECPublicKey;
import java.security.interfaces.RSAPublicKey;
import java.util.*;

/** Explicit leaf-SPKI trust for one server, never a global trust-all override. */
public final class PinnedTls {
    private PinnedTls() {}
    public static String checkedPin(String value) throws GeneralSecurityException {
        if(value==null || !value.trim().matches("[0-9a-fA-F]{64}"))throw new GeneralSecurityException("invalid pin");
        return value.trim().toLowerCase(Locale.ROOT);
    }
    private static byte[] literalIp(String raw) {
        String host=raw;
        if(host.startsWith("[") && host.endsWith("]"))host=host.substring(1,host.length()-1);
        try {
            if(host.indexOf(':')>=0 && host.matches("[0-9a-fA-F:.]+"))return InetAddress.getByName(host).getAddress();
            if(!host.matches("[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+"))return null;
            String[] parts=host.split("\\.");byte[] address=new byte[4];
            for(int i=0;i<4;i++){if(parts[i].length()>1 && parts[i].startsWith("0"))return null;int n=Integer.parseInt(parts[i]);if(n>255)return null;address[i]=(byte)n;}
            return address;
        }catch(Exception invalid){return null;}
    }
    private static boolean matchesSan(X509Certificate certificate,String host)throws CertificateException {
        Collection<List<?>> names=certificate.getSubjectAlternativeNames();if(names==null)return false;
        byte[] ip=literalIp(host);
        for(List<?> name:names) {
            if(name.size()<2 || !(name.get(0) instanceof Integer))continue;
            int type=(Integer)name.get(0);Object value=name.get(1);
            if(ip!=null && type==7) {
                byte[] candidate=value instanceof String?literalIp((String)value):value instanceof byte[]?(byte[])value:null;
                if(candidate!=null && MessageDigest.isEqual(ip,candidate))return true;
            }
            if(ip==null && type==2 && value instanceof String && host.equalsIgnoreCase((String)value))return true;
        }
        return false; // No CN fallback or wildcard matching.
    }
    public static SSLSocketFactory factory(String host,String pin)throws GeneralSecurityException {
        if(host==null || host.isEmpty())throw new GeneralSecurityException("host required");
        String normalized=checkedPin(pin);byte[] expected=new byte[32];
        for(int i=0;i<32;i++)expected[i]=(byte)Integer.parseInt(normalized.substring(i*2,i*2+2),16);
        X509TrustManager trust=new X509TrustManager(){
            public X509Certificate[] getAcceptedIssuers(){return new X509Certificate[0];}
            public void checkClientTrusted(X509Certificate[] chain,String authType)throws CertificateException {throw new CertificateException("client authentication unsupported");}
            public void checkServerTrusted(X509Certificate[] chain,String authType)throws CertificateException {
                try {
                    if(chain==null || chain.length!=1 || chain[0]==null)throw new CertificateException("one self-signed leaf required");
                    X509Certificate leaf=chain[0];
                    byte[] actual=MessageDigest.getInstance("SHA-256").digest(leaf.getPublicKey().getEncoded());
                    if(!MessageDigest.isEqual(expected,actual))throw new CertificateException("server key mismatch");
                    leaf.checkValidity();
                    if(leaf.hasUnsupportedCriticalExtension() || leaf.getBasicConstraints()!=-1)throw new CertificateException("unsupported leaf certificate");
                    if(!leaf.getSubjectX500Principal().equals(leaf.getIssuerX500Principal()))throw new CertificateException("self-signed leaf required");
                    leaf.verify(leaf.getPublicKey());
                    boolean[] usage=leaf.getKeyUsage();List<String> eku=leaf.getExtendedKeyUsage();
                    if(usage==null || usage.length==0 || !usage[0] || eku==null || !eku.contains("1.3.6.1.5.5.7.3.1"))throw new CertificateException("server-auth certificate required");
                    boolean strong=(leaf.getPublicKey() instanceof ECPublicKey && ((ECPublicKey)leaf.getPublicKey()).getParams().getCurve().getField().getFieldSize()>=256)
                        || (leaf.getPublicKey() instanceof RSAPublicKey && ((RSAPublicKey)leaf.getPublicKey()).getModulus().bitLength()>=2048);
                    if(!strong || !matchesSan(leaf,host))throw new CertificateException("invalid server key or address");
                }catch(GeneralSecurityException error){throw new CertificateException("pinned server verification failed",error);}
            }
        };
        SSLContext context=SSLContext.getInstance("TLS");context.init(null,new TrustManager[]{trust},null);
        return new ModernFactory(context.getSocketFactory());
    }
    private static final class ModernFactory extends SSLSocketFactory {
        private final SSLSocketFactory delegate;
        ModernFactory(SSLSocketFactory delegate){this.delegate=delegate;}
        private Socket secure(Socket raw)throws IOException {
            if(!(raw instanceof SSLSocket))throw new IOException("TLS socket required");
            SSLSocket socket=(SSLSocket)raw;List<String> enabled=new ArrayList<>();
            for(String protocol:socket.getSupportedProtocols())if(protocol.equals("TLSv1.2")||protocol.equals("TLSv1.3"))enabled.add(protocol);
            if(enabled.isEmpty()){socket.close();throw new IOException("modern TLS required");}
            socket.setEnabledProtocols(enabled.toArray(new String[0]));return socket;
        }
        public String[] getDefaultCipherSuites(){return delegate.getDefaultCipherSuites();}
        public String[] getSupportedCipherSuites(){return delegate.getSupportedCipherSuites();}
        public Socket createSocket()throws IOException{return secure(delegate.createSocket());}
        public Socket createSocket(Socket socket,String host,int port,boolean close)throws IOException{return secure(delegate.createSocket(socket,host,port,close));}
        public Socket createSocket(String host,int port)throws IOException{return secure(delegate.createSocket(host,port));}
        public Socket createSocket(String host,int port,InetAddress local,int localPort)throws IOException{return secure(delegate.createSocket(host,port,local,localPort));}
        public Socket createSocket(InetAddress host,int port)throws IOException{return secure(delegate.createSocket(host,port));}
        public Socket createSocket(InetAddress host,int port,InetAddress local,int localPort)throws IOException{return secure(delegate.createSocket(host,port,local,localPort));}
    }
}
