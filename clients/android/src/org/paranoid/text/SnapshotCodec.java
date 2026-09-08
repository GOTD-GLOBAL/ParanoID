package org.paranoid.text;

import javax.crypto.Cipher;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import java.security.GeneralSecurityException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/** Standard AES-GCM storage encryption; the Android adapter owns the key. */
public final class SnapshotCodec {
    private static final int MAX = 8 * 1024 * 1024;
    private static final byte[] VERSION = new byte[]{1};
    private SnapshotCodec() {}
    public static byte[] seal(SecretKey key, String value) throws GeneralSecurityException {
        byte[] plaintext=value.getBytes(StandardCharsets.UTF_8);
        if(plaintext.length>MAX)throw new GeneralSecurityException("snapshot limit");
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE,key); // Provider chooses a fresh random nonce.
        cipher.updateAAD(VERSION);
        byte[] iv=cipher.getIV();
        if(iv.length!=12)throw new GeneralSecurityException("unsupported nonce length");
        byte[] ciphertext=cipher.doFinal(plaintext);
        Arrays.fill(plaintext,(byte)0);
        return ByteBuffer.allocate(1+iv.length+ciphertext.length).put(VERSION).put(iv).put(ciphertext).array();
    }
    public static String open(SecretKey key, byte[] value) throws GeneralSecurityException {
        if(value.length<29 || value.length>MAX+29 || value[0]!=VERSION[0])throw new GeneralSecurityException("invalid snapshot");
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE,key,new GCMParameterSpec(128,Arrays.copyOfRange(value,1,13)));
        cipher.updateAAD(VERSION);
        byte[] plaintext=cipher.doFinal(Arrays.copyOfRange(value,13,value.length));
        String result=new String(plaintext,StandardCharsets.UTF_8);
        Arrays.fill(plaintext,(byte)0);
        return result; // Java/Rust string copies cannot promise complete zeroization.
    }
}
