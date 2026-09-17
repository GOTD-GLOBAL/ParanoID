"""JVM adapter test using synthetic Android API stubs, not device evidence."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
STUBS = {
    'android/content/Context.java': '''package android.content;
public class Context {
 private final java.io.File dir;
 public Context(java.io.File dir){this.dir=dir;}
 public Context getApplicationContext(){return this;}
 public java.io.File getFilesDir(){return dir;}
 public String getPackageName(){return "synthetic.test";}
 public android.content.pm.PackageManager getPackageManager(){return new android.content.pm.PackageManager();}
 public <T> T getSystemService(Class<T> type){return type.cast(new android.app.ActivityManager());}
}''',
    'android/content/pm/PackageManager.java': '''package android.content.pm;
public class PackageManager {public PackageInfo getPackageInfo(String n,int f){return new PackageInfo();}}''',
    'android/content/pm/PackageInfo.java': '''package android.content.pm;
public class PackageInfo {public String versionName="synthetic";}''',
    'android/os/Build.java': '''package android.os;
public class Build {public static class VERSION {public static int SDK_INT=35;}}''',
    'android/app/ActivityManager.java': '''package android.app;
public class ActivityManager {
 public static volatile Thread lastThread;
 public java.util.List<ApplicationExitInfo> getHistoricalProcessExitReasons(String p,int pid,int max){
 lastThread=Thread.currentThread();
 java.util.List<ApplicationExitInfo> records=java.util.Arrays.asList(new ApplicationExitInfo(0),new ApplicationExitInfo());
 return records.subList(0,Math.min(max,records.size()));}
}''',
    'android/app/ApplicationExitInfo.java': '''package android.app;
public class ApplicationExitInfo {
 public static final int REASON_CRASH=4, REASON_CRASH_NATIVE=5, REASON_ANR=6,
 REASON_SIGNALED=2, REASON_LOW_MEMORY=3, REASON_EXCESSIVE_RESOURCE_USAGE=9;
 public static int traceCalls, descriptionCalls;
 private final int reason;
 public ApplicationExitInfo(){this(REASON_CRASH_NATIVE);}
 public ApplicationExitInfo(int reason){this.reason=reason;}
 public int getReason(){return reason;}
 public int getStatus(){return 6;}
 public int getImportance(){return 100;}
 public long getTimestamp(){return 1800000000000L;}
 public int getPid(){return 123;}
 public String getDescription(){descriptionCalls++;return "SYNTHETIC_PRIVATE_DESCRIPTION";}
 public java.io.InputStream getTraceInputStream(){traceCalls++;return new java.io.ByteArrayInputStream("SYNTHETIC_TRACE_BYTES".getBytes(java.nio.charset.StandardCharsets.UTF_8));}
}''',
    'org/paranoid/text/CrashExitSmoke.java': '''package org.paranoid.text;
public class CrashExitSmoke {
 public static void main(String[] args) {
  android.content.Context context=new android.content.Context(new java.io.File(args[0]));
  CrashLog.Report pending=CrashLog.peek(context);
  String report=pending==null?null:pending.text;
  if(report==null||!report.contains("CRASH_NATIVE")||!report.contains("status=6"))throw new AssertionError("structured exit missing");
  if(report.contains("SYNTHETIC_PRIVATE_DESCRIPTION")||report.contains("SYNTHETIC_TRACE_BYTES"))throw new AssertionError("raw platform payload entered export");
  if(android.app.ApplicationExitInfo.traceCalls!=0||android.app.ApplicationExitInfo.descriptionCalls!=0)throw new AssertionError("raw platform payload was accessed");
  if(CrashLog.peek(context)==null)throw new AssertionError("peek acknowledged before user action");
  CrashLog.acknowledgeNow(context,pending);
  if(CrashLog.peek(context)!=null)throw new AssertionError("acknowledged exit repeated");
  java.util.concurrent.BlockingQueue<Runnable> ui=new java.util.concurrent.ArrayBlockingQueue<>(1);
  final boolean[] delivered={false};
  CrashLog.load(context,ui::add,r->{delivered[0]=true;});
  try {Runnable delivery=ui.poll(5,java.util.concurrent.TimeUnit.SECONDS);if(delivery==null||delivered[0])throw new AssertionError("delivery executor not respected");delivery.run();}
  catch(InterruptedException e){throw new AssertionError(e);}
  if(!delivered[0])throw new AssertionError("missing async delivery");
  if(android.app.ActivityManager.lastThread==Thread.currentThread())throw new AssertionError("collected on caller/UI thread");
  android.os.Build.VERSION.SDK_INT=29;
  if(CrashLog.peek(context)!=null)throw new AssertionError("old API not gated");
  System.out.println("CrashExitSmoke PASS: bounded structured native exit, no raw API payload access, dedup, API29 gate (synthetic JVM adapter)");
 }
}''',
}

class CrashExit(unittest.TestCase):
    def test_no_raw_platform_payload_is_read_or_exported(self):
        with tempfile.TemporaryDirectory(prefix='paranoid-crash-exit-') as temp:
            root = Path(temp)
            sources = []
            for name, content in STUBS.items():
                path = root/name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
                sources.append(str(path))
            sources.append(str(ROOT/'src/org/paranoid/text/CrashLog.java'))
            output = root/'classes'
            subprocess.run(['javac', '--release', '8', '-d', str(output), *sources], check=True)
            data = root/'data'
            data.mkdir()
            subprocess.run(['java', '-cp', str(output), 'org.paranoid.text.CrashExitSmoke', str(data)], check=True)

if __name__ == '__main__':
    unittest.main()
