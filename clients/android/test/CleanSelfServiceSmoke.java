import org.paranoid.text.*;
import org.json.JSONObject;
import java.io.IOException;

/** Fresh-install adapter contract; archived SelfServiceSmoke remains unchanged. */
public final class CleanSelfServiceSmoke {
    public static void main(String[] args) throws Exception {
        String[] disk={null};
        SelfServiceClient client=new SelfServiceClient(null,value->disk[0]=value);
        client.createIdentity();
        if(disk[0]==null)throw new AssertionError("identity not durably saved");
        JSONObject first=new JSONObject(disk[0]);
        if(first.getInt("version")!=4 || first.getJSONObject("state").getInt("version")!=3)
            throw new AssertionError("fresh install must persist wrapper4/core3 clean channel schema");
        String saved=disk[0];
        client.createIdentity();
        if(!saved.equals(disk[0]))throw new AssertionError("retry changed saved keys");
        client=new SelfServiceClient(saved,value->disk[0]=value);
        JSONObject view=client.publicView();
        if(!view.getBoolean("identity") || view.getBoolean("active") || view.getJSONArray("dialogs").length()!=0)
            throw new AssertionError("fresh offline ID view is not zero-contact/unregistered");
        for(int version:new int[]{0,2,3}) {
            String old=new JSONObject(saved).put("version",version).toString();
            int[] saves={0};
            try {new SelfServiceClient(old,value->saves[0]++);throw new AssertionError("historical wrapper accepted");}
            catch(IOException expected){if(!expected.getMessage().contains("unsupported"))throw expected;}
            if(saves[0]!=0)throw new AssertionError("unsupported snapshot was overwritten");
        }
        JSONObject oldNative=new JSONObject(saved);oldNative.getJSONObject("state").put("version",2);
        try {new SelfServiceClient(oldNative.toString(),value->{throw new AssertionError("old native snapshot overwritten");});
            throw new AssertionError("historical native state accepted");}
        catch(IOException expected){if(!expected.getMessage().contains("unsupported"))throw expected;}
        SelfServiceClient broken=new SelfServiceClient(null,value->{throw new IOException("fixture storage fault");});
        try{broken.createIdentity();throw new AssertionError("write error ignored");}catch(IOException expected){}
        if(!broken.broken())throw new AssertionError("ambiguous storage did not freeze");
        try{broken.publicView();throw new AssertionError("frozen client still operates");}catch(IOException expected){}
        try{new SelfServiceClient("{}",value->{});throw new AssertionError("corrupt snapshot reset");}catch(Exception expected){}
        System.out.println("PASS clean actual JVM/JNI: durable wrapper4/core3, zero contacts, stable ID/retry/reopen, unsupported older snapshots preserve bytes, failed storage freezes");
    }
}
