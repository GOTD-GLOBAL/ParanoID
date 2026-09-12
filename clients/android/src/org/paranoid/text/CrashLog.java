package org.paranoid.text;

import android.content.Context;
import java.io.File;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

/** Last uncaught exception, kept locally (app-private files) so the owner can paste it into the
 *  bug report. Nothing is sent anywhere; the file is deleted when dismissed. */
final class CrashLog {
    private static final String NAME="last-crash.txt";
    private static volatile boolean installed;
    static synchronized void install(Context context){
        if(installed)return;installed=true;
        final File file=new File(context.getApplicationContext().getFilesDir(),NAME);
        final Thread.UncaughtExceptionHandler previous=Thread.getDefaultUncaughtExceptionHandler();
        Thread.setDefaultUncaughtExceptionHandler((thread,error)->{
            try{
                StringWriter text=new StringWriter();
                text.write("ParanoID "+version(context)+" thread "+thread.getName()+" "+new java.util.Date()+"\n");
                error.printStackTrace(new PrintWriter(text));
                String body=text.toString();if(body.length()>16384)body=body.substring(0,16384);
                Files.write(file.toPath(),body.getBytes(StandardCharsets.UTF_8));
            }catch(Throwable ignored){}
            if(previous!=null)previous.uncaughtException(thread,error);
        });
    }
    private static String version(Context context){
        try{return context.getPackageManager().getPackageInfo(context.getPackageName(),0).versionName;}catch(Exception e){return "?";}
    }
    static String take(Context context){
        File file=new File(context.getFilesDir(),NAME);
        String java=null;
        if(file.isFile()){try{java=new String(Files.readAllBytes(file.toPath()),StandardCharsets.UTF_8);}catch(Exception e){java=null;}}
        String exit=lastExit(context);
        if(java==null&&exit==null)return null;
        return (exit==null?"":exit+"\n\n")+(java==null?"":java);
    }
    private static final String SEEN="last-exit-seen";
    /** Android 11+: the system's own record of why our process last died. Covers native crashes
     *  (SIGSEGV/SIGABRT in WebRTC etc.) which never reach the Java uncaught handler. Each exit is
     *  reported once. */
    private static String lastExit(Context context){
        if(android.os.Build.VERSION.SDK_INT<30)return null;
        try{
            android.app.ActivityManager am=context.getSystemService(android.app.ActivityManager.class);
            java.util.List<android.app.ApplicationExitInfo> exits=am.getHistoricalProcessExitReasons(context.getPackageName(),0,1);
            if(exits.isEmpty())return null;
            android.app.ApplicationExitInfo e=exits.get(0);
            int reason=e.getReason();
            if(reason!=android.app.ApplicationExitInfo.REASON_CRASH&&reason!=android.app.ApplicationExitInfo.REASON_CRASH_NATIVE
                &&reason!=android.app.ApplicationExitInfo.REASON_ANR&&reason!=android.app.ApplicationExitInfo.REASON_SIGNALED
                &&reason!=android.app.ApplicationExitInfo.REASON_LOW_MEMORY&&reason!=android.app.ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE)return null;
            String key=e.getTimestamp()+":"+e.getPid();
            java.io.File marker=new java.io.File(context.getFilesDir(),SEEN);
            if(marker.isFile()&&key.equals(new String(Files.readAllBytes(marker.toPath()),StandardCharsets.UTF_8)))return null;
            Files.write(marker.toPath(),key.getBytes(StandardCharsets.UTF_8));
            String name;switch(reason){
                case android.app.ApplicationExitInfo.REASON_CRASH:name="CRASH (Java)";break;
                case android.app.ApplicationExitInfo.REASON_CRASH_NATIVE:name="CRASH_NATIVE";break;
                case android.app.ApplicationExitInfo.REASON_ANR:name="ANR";break;
                case android.app.ApplicationExitInfo.REASON_SIGNALED:name="SIGNALED";break;
                case android.app.ApplicationExitInfo.REASON_LOW_MEMORY:name="LOW_MEMORY";break;
                default:name="EXCESSIVE_RESOURCE_USAGE";}
            StringBuilder out=new StringBuilder("System exit record: "+name+" status="+e.getStatus()+" importance="+e.getImportance()+" at "+new java.util.Date(e.getTimestamp())+"\n");
            if(e.getDescription()!=null)out.append("description: ").append(e.getDescription()).append('\n');
            try(java.io.InputStream trace=e.getTraceInputStream()){
                if(trace!=null){byte[] buf=new byte[12288];int n=trace.read(buf);if(n>0)out.append("trace:\n").append(new String(buf,0,n,StandardCharsets.UTF_8));}
            }catch(Exception ignored){}
            return out.toString();
        }catch(Throwable ignored){return null;}
    }
    static void clear(Context context){new File(context.getFilesDir(),NAME).delete();}
}
