package org.paranoid.devnet;
import android.app.*;
import android.os.Bundle;
import android.content.Context;
import java.io.*;
import org.json.JSONObject;

/** Disposable emulator-only package; public vectors, no live RPC or funded keys. */
public final class StorageAcceptance extends Instrumentation {
    private String phase;
    @Override public void onCreate(Bundle args){super.onCreate(args);phase=args.getString("phase","write");start();}
    @Override public void onStart(){
        Bundle result=new Bundle();
        try {
            Context context=getTargetContext();
            if(!context.getPackageName().equals("global.paranoid.devnet.acceptance"))throw new AssertionError("wrong test package");
            JSONObject pins=SolanaBridge.run(new JSONObject().put("op","program_info"));
            DevnetStore store=new DevnetStore(context);
            if(phase.equals("write")){
                if(store.load()!=null)throw new AssertionError("test package is not fresh");
                JSONObject state=new JSONObject().put("entropy","AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=").put("program",pins.getString("program")).put("genesis",pins.getString("genesis")).put("backup",true).put("attempts",new org.json.JSONArray());
                store.save(state);
                if(!new DevnetStore(context).load().getString("entropy").equals(state.getString("entropy")))throw new AssertionError("readback");
            } else if(phase.equals("reopen")) {
                if(!store.load().optBoolean("backup"))throw new AssertionError("cross-process reopen");
            } else if(phase.equals("freeze")) {
                File marker=new File(context.getNoBackupFilesDir(),"devnet-write.pending");
                try(FileOutputStream out=new FileOutputStream(marker)){out.write(1);out.getFD().sync();}
                boolean refused=false;
                try{new DevnetStore(context).load();}catch(IOException expected){refused=true;}
                if(!refused)throw new AssertionError("restart ignored durable write-intent marker");
            } else throw new AssertionError("unknown phase");
            result.putString("result","PASS "+phase+" (real Android Keystore/AtomicFile, emulator only)");finish(Activity.RESULT_OK,result);
        } catch(Throwable error){result.putString("failure",error.getClass().getSimpleName()+": "+error.getMessage());finish(Activity.RESULT_CANCELED,result);}
    }
}
