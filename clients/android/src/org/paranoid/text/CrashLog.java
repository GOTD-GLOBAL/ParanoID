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
        if(!file.isFile())return null;
        try{return new String(Files.readAllBytes(file.toPath()),StandardCharsets.UTF_8);}catch(Exception e){return null;}
    }
    static void clear(Context context){new File(context.getFilesDir(),NAME).delete();}
}
