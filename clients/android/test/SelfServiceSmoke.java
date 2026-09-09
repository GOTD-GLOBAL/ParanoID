import org.paranoid.text.*;
import org.json.JSONObject;
import java.io.IOException;
import java.lang.reflect.*;
public final class SelfServiceSmoke {
    public static void main(String[] args) throws Exception {
        Class<?> type;
        try {type=Class.forName("org.paranoid.text.SelfServiceClient");}
        catch(ClassNotFoundException missing){throw new AssertionError("self-service client adapter is missing");}
        String[] disk={null};
        Object client=type.getConstructor(String.class,KeyClient.Commit.class).newInstance(null,(KeyClient.Commit)value->disk[0]=value);
        type.getMethod("createIdentity").invoke(client);
        if(disk[0]==null)throw new AssertionError("identity not durably saved");
        JSONObject first=new JSONObject(disk[0]);
        if(first.getJSONObject("state").getInt("version")!=2)throw new AssertionError("client did not migrate to v2 core");
        String saved=disk[0];
        type.getMethod("createIdentity").invoke(client);
        if(!saved.equals(disk[0]))throw new AssertionError("retry changed saved keys");
        client=type.getConstructor(String.class,KeyClient.Commit.class).newInstance(saved,(KeyClient.Commit)value->disk[0]=value);
        JSONObject view=(JSONObject)type.getMethod("publicView").invoke(client);
        if(!view.getBoolean("identity") || view.getBoolean("active"))throw new AssertionError("invalid offline ID view");
        Object broken=type.getConstructor(String.class,KeyClient.Commit.class).newInstance(null,(KeyClient.Commit)value->{throw new IOException("fixture storage fault");});
        try{type.getMethod("createIdentity").invoke(broken);throw new AssertionError("write error ignored");}catch(InvocationTargetException expected){}
        if(!(Boolean)type.getMethod("broken").invoke(broken))throw new AssertionError("ambiguous storage did not freeze");
        try{type.getConstructor(String.class,KeyClient.Commit.class).newInstance("{}",(KeyClient.Commit)value->{});throw new AssertionError("corrupt snapshot reset");}catch(InvocationTargetException expected){}
        System.out.println("PASS self-service actual JVM/JNI: offline ID saved, v2 migration, retry/reload preserves identity, failed storage freezes");
    }
}
