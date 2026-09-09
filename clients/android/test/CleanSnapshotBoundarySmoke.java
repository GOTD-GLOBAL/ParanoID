import org.paranoid.text.*;
import org.json.JSONObject;
import java.io.IOException;

/** Native0 is only an interrupted pristine identity creation, never a migration lane. */
public final class CleanSnapshotBoundarySmoke {
    static JSONObject call(String state,JSONObject request) throws Exception {
        JSONObject result=new JSONObject(CoreBridge.command(state,request.toString()));
        if(result.has("error"))throw new AssertionError("fixture setup: "+result.getString("error"));
        return result;
    }
    static JSONObject request(String op){return new JSONObject().put("op",op);}
    static String saved(JSONObject state) {
        return new JSONObject().put("version",4).put("realm","https://127.0.0.2:38443").put("tls_pin",new String(new char[64]).replace('\0','a'))
            .put("token","").put("state",state).toString();
    }
    public static void main(String[] args) throws Exception {
        String realm="https://127.0.0.2:38443",pin=new String(new char[64]).replace('\0','a');
        JSONObject a=call("",request("init").put("device","alice").put("realm",realm));
        JSONObject b=call("",request("init").put("device","bob").put("realm",realm));
        a=call(a.getJSONObject("state").toString(),request("pair").put("peer",b.getJSONObject("public")).put("verified",true));
        a=call(a.getJSONObject("state").toString(),request("send").put("text","actual retained historical message"));
        a=call(a.getJSONObject("state").toString(),request("create_identity").put("realm",realm).put("pin",pin));
        if(a.getJSONObject("state").getJSONArray("history").length()!=1)throw new AssertionError("populated fixture is empty");
        String retained=saved(a.getJSONObject("state"));int[] saves={0};
        try {new SelfServiceClient(retained,value->saves[0]++);throw new AssertionError("populated historical native0 opened through wrapper4");}
        catch(IOException expected){if(!expected.getMessage().contains("unsupported"))throw expected;}
        if(saves[0]!=0)throw new AssertionError("historical native0 overwritten");
        JSONObject pristine=call("",request("create_identity").put("realm",realm).put("pin",pin));
        String pristineDisk=saved(pristine.getJSONObject("state"));String[] disk={pristineDisk};
        SelfServiceClient client=new SelfServiceClient(pristineDisk,value->disk[0]=value);
        if(!disk[0].equals(pristineDisk))throw new AssertionError("opening snapshot unexpectedly wrote state");
        client.createIdentity();
        JSONObject upgraded=new JSONObject(disk[0]);
        if(upgraded.getJSONObject("state").getInt("version")!=3)throw new AssertionError("pristine interrupted create did not finish clean schema");
        if(!client.publicView().getString("account").equals(pristine.getJSONObject("request").getJSONObject("credential").getString("account")))
            throw new AssertionError("interrupted creation replaced account");
        System.out.println("PASS actual JNI snapshot boundary: populated historical native0 refused unchanged; pristine interrupted creation reopens and upgrades same ID");
    }
}
