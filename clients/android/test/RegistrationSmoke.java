import org.paranoid.text.*;
import org.json.JSONObject;
import java.io.IOException;
public final class RegistrationSmoke {
    public static void main(String[] args) throws Exception {
        try{StorageGuard.requireContinuity(false,true);throw new AssertionError("missing snapshot must not mint replacement identity");}catch(IOException expected){}
        try{StorageGuard.requireContinuity(true,false);throw new AssertionError("missing wrapping key must not regenerate");}catch(IOException expected){}
        StorageGuard.requireContinuity(false,false);StorageGuard.requireContinuity(true,true);
        final String[] disk={null}; final int[] writes={0};
        KeyClient client=new KeyClient(null, value->{disk[0]=value;writes[0]++;});
        client.createIdentity();
        if(disk[0]==null || writes[0]!=1)throw new AssertionError("identity must be committed locally");
        String first=disk[0];
        client.createIdentity();
        if(!first.equals(disk[0]))throw new AssertionError("duplicate create changed keys");
        client=new KeyClient(disk[0], value->{disk[0]=value;});
        if(!client.publicView().getBoolean("identity"))throw new AssertionError("identity did not reopen");
        KeyClient failed=new KeyClient(null,value->{throw new IOException("synthetic storage failure");});
        try{failed.createIdentity();throw new AssertionError("storage failure ignored");}catch(IOException expected){}
        try{failed.createIdentity();throw new AssertionError("ambiguous write must freeze");}catch(IOException expected){}
        if(!failed.broken())throw new AssertionError("state not frozen");
        try{new KeyClient("corrupt state",value->{});throw new AssertionError("corrupt state reset");}catch(Exception expected){}
        System.out.println("PASS REG-01: real JNI creation, durable-before-use, duplicate Create ID, reopen, storage failure freezes; no network");
    }
}
