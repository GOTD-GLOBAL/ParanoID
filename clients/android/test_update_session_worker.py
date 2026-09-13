#!/usr/bin/env python3
"""Execute the exact production sessionInstall method with host API adapters.
Not Android Binder/PackageInstaller/device evidence. No real installation.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent


def main():
    controller = (ROOT / 'src/org/paranoid/text/UpdateController.java').read_text()
    method = controller[controller.index('    private void sessionInstall('):controller.index('    public static final String INSTALL_STATUS')]
    sources = {
        'android/content/Intent.java': '''package android.content;
public class Intent {public static final int FLAG_ACTIVITY_SINGLE_TOP=1,FLAG_ACTIVITY_CLEAR_TOP=2;
public Intent(Object context,Class<?> type){} public Intent setAction(String a){return this;}
public Intent addFlags(int f){return this;}}''',
        'android/os/Build.java': '''package android.os;
public class Build {public static class VERSION {public static final int SDK_INT=35;}}''',
        'android/app/PendingIntent.java': '''package android.app;
public class PendingIntent {public static final int FLAG_UPDATE_CURRENT=1,FLAG_MUTABLE=2;
public static PendingIntent getActivity(Object a,int id,Object intent,int flags){return new PendingIntent();}
public Object getIntentSender(){return this;}}''',
        'android/content/pm/PackageInstaller.java': '''package android.content.pm;
import java.io.*;import java.util.concurrent.*;
public class PackageInstaller {
public final Session session=new Session();public boolean openFails,abandonedById;
public int createSession(SessionParams p){return 1;}
public Session openSession(int id)throws IOException {if(openFails)throw new IOException("open failed");return session;}
public void abandonSession(int id){abandonedById=true;}
public static class SessionParams {public static final int MODE_FULL_INSTALL=1;public SessionParams(int m){}
public void setAppPackageName(String n){}public void setSize(long n){}}
public static class Session {
public boolean abandoned,closed,committed,closeFails;public Thread copyThread,commitThread,fsyncThread;
public final CountDownLatch entered=new CountDownLatch(1),release=new CountDownLatch(1);
public OutputStream openWrite(String n,long start,long size){copyThread=Thread.currentThread();return new OutputStream(){
public void write(int b)throws IOException{}public void write(byte[] b,int o,int n)throws IOException{
entered.countDown();try{if(!release.await(5,TimeUnit.SECONDS))throw new IOException("test gate timeout");}
catch(InterruptedException e){throw new IOException(e);}}};}
public void fsync(OutputStream o){fsyncThread=Thread.currentThread();}
public void commit(Object sender){committed=true;commitThread=Thread.currentThread();}
public void abandon(){abandoned=true;}public void close(){closed=true;if(closeFails)throw new RuntimeException("close Binder fixture");}
}}
''',
    }
    harness = '''package org.paranoid.text;
import java.io.*;import java.nio.file.*;import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import android.content.Intent;import android.app.PendingIntent;import android.os.Build;
public class SessionWorkerSmoke {
static final ExecutorService WORK=Executors.newSingleThreadExecutor();
static final AtomicBoolean BUSY=new AtomicBoolean();static final String INSTALL_STATUS="test";
static class MainActivity {}
static class Text {public void setText(String s){}}
static class Manager {boolean acquireFails;final android.content.pm.PackageInstaller installer=new android.content.pm.PackageInstaller();
public android.content.pm.PackageInstaller getPackageInstaller(){if(acquireFails)throw new RuntimeException("acquire Binder fixture");return installer;}}
static class Activity {final Manager manager=new Manager();boolean focus=true,alive=true;
final BlockingQueue<Runnable> ui=new LinkedBlockingQueue<>();
public Manager getPackageManager(){return manager;}public String getPackageName(){return "global.paranoid.messenger";}
public boolean hasWindowFocus(){return focus;}public void runOnUiThread(Runnable r){ui.add(r);}}
final Activity activity=new Activity();final Text status=new Text();UpdateManifest manifest;
boolean alive(){return activity.alive;}void finish(){BUSY.set(false);}
''' + method + '''
static void require(boolean yes,String message){if(!yes)throw new AssertionError(message);}
public static void main(String[] args)throws Exception {
Path apk=Files.createTempFile("session-copy-fixture-",".bin");Files.write(apk,new byte[]{1,2,3});
try {
for(String mode:new String[]{"success","focus-lost","destroyed","bad-hash","open-failed","close-success","close-cancel","acquire-failed"}) {
SessionWorkerSmoke h=new SessionWorkerSmoke();
String hash="039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81";
String json="{\\"schema\\":1,\\"package\\":\\"global.paranoid.messenger\\",\\"version_code\\":26,\\"version_name\\":\\"test\\",\\"min_sdk\\":26,\\"abi\\":\\"arm64-v8a\\",\\"apk_sha256\\":\\""+hash+"\\",\\"apk_size\\":3}";
h.manifest=UpdateManifest.parse(json.getBytes("UTF-8"));
if(mode.equals("bad-hash"))Files.write(apk,new byte[]{3,2,1});else Files.write(apk,new byte[]{1,2,3});
h.activity.manager.installer.openFails=mode.equals("open-failed");
h.activity.manager.acquireFails=mode.equals("acquire-failed");
h.activity.manager.installer.session.closeFails=mode.startsWith("close-");
android.content.pm.PackageInstaller.Session s=h.activity.manager.installer.session;
BUSY.set(true);h.sessionInstall(apk.toFile(),"fixture intent failure");
if(!mode.equals("open-failed")&&!mode.equals("acquire-failed")){
require(s.entered.await(5,TimeUnit.SECONDS),"worker copy started");
require(s.copyThread!=Thread.currentThread(),"copy must not run on caller/UI");
require(BUSY.get(),"BUSY released during copy");
require(h.activity.ui.isEmpty(),"UI dispatched before copy complete");
if(mode.equals("focus-lost")||mode.equals("close-cancel"))h.activity.focus=false;
if(mode.equals("destroyed"))h.activity.alive=false;
s.release.countDown();}
Runnable ui=h.activity.ui.poll(5,TimeUnit.SECONDS);require(ui!=null,"UI completion missing");ui.run();
require(!BUSY.get(),"BUSY leaked");
if(mode.equals("success")||mode.equals("close-success")){
require(s.committed&&!s.abandoned&&s.closed,"success commit/close");
require(s.commitThread==Thread.currentThread(),"commit must run on UI");
require(s.fsyncThread==s.copyThread,"fsync must run on worker");
}else if(mode.equals("acquire-failed"))require(!s.committed,"acquire failure committed");
else if(mode.equals("open-failed"))require(h.activity.manager.installer.abandonedById&&!s.committed,"failed open leaked session");
else require(s.abandoned&&s.closed&&!s.committed,"failure/background must abandon and close without commit");
System.out.println("Session worker "+mode+" PASS (host adapter, not Android install)");
}
}finally{Files.delete(apk);WORK.shutdownNow();}
}
}
'''
    sources['org/paranoid/text/SessionWorkerSmoke.java'] = harness
    with tempfile.TemporaryDirectory(prefix='paranoid-session-worker-') as tmp:
        tmp = Path(tmp)
        files = []
        for name, text in sources.items():
            p = tmp / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)
            files.append(str(p))
        files.append(str(ROOT / 'src/org/paranoid/text/UpdateManifest.java'))
        subprocess.run(['javac', '--release', '8', '-Xlint:-options', '-d', str(tmp), *files], check=True)
        subprocess.run(['java', '-cp', str(tmp), 'org.paranoid.text.SessionWorkerSmoke'], check=True, timeout=40)


if __name__ == '__main__':
    main()
