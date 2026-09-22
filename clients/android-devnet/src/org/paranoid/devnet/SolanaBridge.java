package org.paranoid.devnet;
import org.json.JSONObject;
final class SolanaBridge {
    static { System.loadLibrary("paranoid_devnet_client"); }
    private static native String call(String input);
    static JSONObject run(JSONObject input)throws Exception {
        if(input.toString().length()>8192)throw new java.io.IOException("input_limit");
        JSONObject output=new JSONObject(call(input.toString()));
        if(output.has("error"))throw new java.io.IOException(output.getString("error"));
        return output;
    }
}
