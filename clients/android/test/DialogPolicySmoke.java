import org.paranoid.text.*;
import org.json.JSONObject;
import java.lang.reflect.Method;

public final class DialogPolicySmoke {
    public static void main(String[] args) throws Exception {
        Class<?> policy;
        try{policy=Class.forName("org.paranoid.text.DialogPolicy");}
        catch(ClassNotFoundException missing){throw new AssertionError("first-contact UI policy is missing");}
        Method reply=policy.getMethod("canReply",JSONObject.class,boolean.class,boolean.class,boolean.class);
        Method label=policy.getMethod("trustLabel",JSONObject.class);
        JSONObject incoming=new JSONObject().put("account","account").put("trust","network_unverified").put("blocked",false);
        if(!(Boolean)reply.invoke(null,incoming,true,false,false))throw new AssertionError("unverified incoming reply requires approval");
        if(!label.invoke(null,incoming).equals("Личность не проверена"))throw new AssertionError("unverified badge missing");
        incoming.put("blocked",true);
        if((Boolean)reply.invoke(null,incoming,true,false,false))throw new AssertionError("blocked contact reply enabled");
        incoming.put("blocked",false).put("trust","out_of_band_verified");
        if(!label.invoke(null,incoming).equals("Личность проверена"))throw new AssertionError("verified badge incorrect");
        for(boolean[] flags:new boolean[][]{{false,false,false},{true,true,false},{true,false,true}})
            if((Boolean)reply.invoke(null,incoming,flags[0],flags[1],flags[2]))throw new AssertionError("disabled send state enabled");
        if((Boolean)reply.invoke(null,null,true,false,false))throw new AssertionError("missing dialog enabled");
        System.out.println("PASS Android UI policy: network-unverified immediate reply, trust text, blocked/offline/frozen/inflight disabled");
    }
}
