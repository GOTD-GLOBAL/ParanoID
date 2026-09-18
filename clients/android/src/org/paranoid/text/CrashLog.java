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
    static Report peek(Context context){
        File file=new File(context.getFilesDir(),NAME);
        String java=null;
        if(file.isFile()){try{java=new String(Files.readAllBytes(file.toPath()),StandardCharsets.UTF_8);}catch(Exception e){java=null;}}
        Exit exit=lastExit(context);
        if(java==null&&exit==null)return null;
        return new Report((exit==null?"":exit.text+"\n\n")+(java==null?"":java),exit==null?null:exit.key,java);
    }
    private static final String SEEN="last-exit-seen";
    /** Android 11+: the system's own record of why our process last died. Covers native crashes
     *  (SIGSEGV/SIGABRT in WebRTC etc.) which never reach the Java uncaught handler. Each exit is
     *  reported once. */
    private static Exit lastExit(Context context){
        if(android.os.Build.VERSION.SDK_INT<30)return null;
        try{
            android.app.ActivityManager am=context.getSystemService(android.app.ActivityManager.class);
            java.util.List<android.app.ApplicationExitInfo> exits=am.getHistoricalProcessExitReasons(context.getPackageName(),0,8);
            android.app.ApplicationExitInfo e=null;
            for(android.app.ApplicationExitInfo candidate:exits){
                int reason=candidate.getReason();
                if(reason==android.app.ApplicationExitInfo.REASON_CRASH||reason==android.app.ApplicationExitInfo.REASON_CRASH_NATIVE
                    ||reason==android.app.ApplicationExitInfo.REASON_ANR||reason==android.app.ApplicationExitInfo.REASON_SIGNALED
                    ||reason==android.app.ApplicationExitInfo.REASON_LOW_MEMORY||reason==android.app.ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE){e=candidate;break;}
            }
            if(e==null)return null;
            int reason=e.getReason();
            String key=e.getTimestamp()+":"+e.getPid();
            java.io.File marker=new java.io.File(context.getFilesDir(),SEEN);
            if(marker.isFile()&&key.equals(new String(Files.readAllBytes(marker.toPath()),StandardCharsets.UTF_8)))return null;
            String name;switch(reason){
                case android.app.ApplicationExitInfo.REASON_CRASH:name="CRASH (Java)";break;
                case android.app.ApplicationExitInfo.REASON_CRASH_NATIVE:name="CRASH_NATIVE";break;
                case android.app.ApplicationExitInfo.REASON_ANR:name="ANR";break;
                case android.app.ApplicationExitInfo.REASON_SIGNALED:name="SIGNALED";break;
                case android.app.ApplicationExitInfo.REASON_LOW_MEMORY:name="LOW_MEMORY";break;
                default:name="EXCESSIVE_RESOURCE_USAGE";}
            StringBuilder out=new StringBuilder("System exit record: "+name+" status="+e.getStatus()+" importance="+e.getImportance()+" at "+new java.util.Date(e.getTimestamp())+"\n");
            // Only structured exit metadata is exported. Native traces on API31+ are
            // protobuf tombstones, not UTF-8; raw traces/descriptions can also contain
            // private process context. Never open that stream on the startup/UI path.
            // Existing Java exception reports remain a separate, unredacted mechanism.
            return new Exit(out.toString(),key);
        }catch(Throwable ignored){return null;}
    }
    static final class Report {
        final String text,exitKey,javaText;
        Report(String text,String exitKey,String javaText){this.text=text;this.exitKey=exitKey;this.javaText=javaText;}
    }
    private static final class Exit {
        final String text,key;
        Exit(String text,String key){this.text=text;this.key=key;}
    }
    private static final java.util.concurrent.Executor IO=new java.util.concurrent.ThreadPoolExecutor(
        1,1,0L,java.util.concurrent.TimeUnit.MILLISECONDS,new java.util.concurrent.ArrayBlockingQueue<Runnable>(8),
        task->{Thread thread=new Thread(task,"paranoid-crash-report");thread.setDaemon(true);return thread;});
    private static void submit(Runnable operation){
        try{IO.execute(operation);}catch(java.util.concurrent.RejectedExecutionException ignored){
            // Diagnostic overload never changes messaging/call authority or acknowledges an unseen report.
        }
    }
    static void load(Context context,java.util.concurrent.Executor delivery,java.util.function.Consumer<Report> callback){
        final Context app=context.getApplicationContext();
        submit(()->{
            Report report=peek(app);
            try{delivery.execute(()->callback.accept(report));}catch(RuntimeException ignored){}
        });
    }
    static void acknowledge(Context context,Report report){
        final Context app=context.getApplicationContext();
        submit(()->acknowledgeNow(app,report));
    }
    static void acknowledgeNow(Context context,Report report){
        if(report==null)return;
        try{
            if(report.exitKey!=null)Files.write(new File(context.getFilesDir(),SEEN).toPath(),report.exitKey.getBytes(StandardCharsets.UTF_8));
            File file=new File(context.getFilesDir(),NAME);
            if(report.javaText!=null&&file.isFile()
                &&report.javaText.equals(new String(Files.readAllBytes(file.toPath()),StandardCharsets.UTF_8)))file.delete();
        }catch(Exception ignored){} // On failure the report may reappear; never clear a different report.
    }
}
