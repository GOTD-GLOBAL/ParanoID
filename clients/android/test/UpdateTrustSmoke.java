package org.paranoid.text;
import java.util.Arrays;
public final class UpdateTrustSmoke {
    public static void main(String[] args)throws Exception {
        String[] saved={null};String realm="https://127.0.0.23:39443",pin=UpdateSmoke.repeat('a',64);
        SelfServiceClient c=new SelfServiceClient(null,s->saved[0]=s,realm,pin);c.createIdentity();
        String before=saved[0];SelfServiceClient loaded=new SelfServiceClient(before,s->{throw new AssertionError("update trust wrote messaging state");});
        java.lang.reflect.Method method;
        try{method=SelfServiceClient.class.getMethod("updateTrust");}catch(NoSuchMethodException e){throw new AssertionError("read-only saved update trust missing",e);}
        String[] trust=(String[])method.invoke(loaded);
        if(!Arrays.equals(trust,new String[]{realm,pin}) || !before.equals(saved[0]))throw new AssertionError("saved pin/origin lost");
        trust[0]="https://other.invalid";
        if(!((String[])method.invoke(loaded))[0].equals(realm))throw new AssertionError("mutable trust leaked");
        System.out.println("UpdateTrustSmoke saved nondefault trust/no state writes PASS");
    }
}
