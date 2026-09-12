package org.paranoid.text;

import android.app.Activity;
import android.app.PendingIntent;
import android.content.*;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import android.widget.*;
import java.io.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

/** One explicit tap per check/download/install. No update action from lifecycle callbacks. */
public final class UpdateController {
    private static final ExecutorService WORK=Executors.newSingleThreadExecutor();
    private static final AtomicBoolean BUSY=new AtomicBoolean();
    private final Activity activity;private final TextEngine engine;
    private final Button button;private final TextView status;
    private UpdateClient client;private UpdateManifest manifest;private File apk;
    private int stage; // 0 check, 1 download, 2 installer
    public UpdateController(Activity activity,TextEngine engine,LinearLayout parent){
        this.activity=activity;this.engine=engine;
        button=new Button(activity);button.setText("Обновить — проверить");parent.addView(button);
        status=new TextView(activity);status.setText("Обновления проверяются только по нажатию. ID и переписка сохраняются.");parent.addView(status);
        button.setOnClickListener(v->tap());
    }
    private boolean alive(){return !activity.isFinishing()&&!activity.isDestroyed();}
    public void showStatus(String message){status.setText(message);}
    /** External "check now" entry: reuses the explicit button, only for a fresh check. */
    public void trigger(){if(stage==0&&!BUSY.get()&&button.isEnabled())button.performClick();}
    private void reset(String message){stage=0;manifest=null;apk=null;button.setText("Обновить — Повторить проверку");status.setText(message);}
    private void finish(){BUSY.set(false);if(alive())button.setEnabled(true);}
    private interface Job{Runnable run()throws Exception;}
    private void background(Job job){WORK.execute(()->{
        try{Runnable result=job.run();activity.runOnUiThread(()->{try{if(alive())result.run();}finally{finish();}});}
        catch(Exception error){activity.runOnUiThread(()->{if(alive())reset("Обновление не прошло проверку или недоступно. Проверьте сеть и нажмите «Повторить». Текущая версия, ID и переписка не изменены.");finish();});}
    });}
    private void tap(){
        if(!BUSY.compareAndSet(false,true)){status.setText("Другая проверка обновления ещё выполняется. Повторите чуть позже.");return;}
        button.setEnabled(false);
        if(stage==0){
            status.setText("Проверяем обновление через сохранённое доверенное подключение…");
            engine.updateTrust(trust->{
                if(!alive()){finish();return;}
                if(trust==null){reset("Сохранённое подключение недоступно. На новом телефоне сначала создайте ID. Не удаляйте данные существующего ID. Повторите проверку позже.");finish();return;}
                background(()->{
                    activity.revokeUriPermission(Uri.parse(UpdatePolicy.URI),Intent.FLAG_GRANT_READ_URI_PERMISSION);
                    client=new UpdateClient(trust[0],trust[1]);UpdateManifest found=client.check();
                    boolean available=found!=null && UpdatePolicy.available(found,AndroidUpdateVerifier.version(AndroidUpdateVerifier.installed(activity)),Build.VERSION.SDK_INT,Build.SUPPORTED_ABIS);
                    return ()->{if(!available)reset("Обновлений пока нет. Установленная версия сохранена; можно проверить позже.");
                        else{manifest=found;stage=1;button.setText("Скачать обновление");status.setText("Доступна версия "+found.versionName+". Скачать APK ("+found.apkSize+" байт)? Установка — отдельным нажатием.");}};
                });
            });
        }else if(stage==1){
            status.setText("Скачиваем и проверяем размер, SHA-256, пакет, версию и подпись APK…");
            background(()->{
                if(!UpdatePolicy.available(manifest,AndroidUpdateVerifier.version(AndroidUpdateVerifier.installed(activity)),Build.VERSION.SDK_INT,Build.SUPPORTED_ABIS))throw new IOException("not newer");
                File ready=client.download(manifest,activity.getCacheDir(),(file,m)->AndroidUpdateVerifier.verify(activity,file,m));
                return ()->{apk=ready;stage=2;button.setText("Установить обновление");status.setText("APK проверен. Нажмите «Установить»: Android попросит подтверждение. Не удаляйте приложение.");};
            });
        }else{
            if(!activity.getPackageManager().canRequestPackageInstalls()){
                status.setText("Android требует разрешить установку из ParanoID. Вернитесь сюда и снова нажмите «Установить». После обновления разрешение можно отключить.");
                try{activity.startActivity(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,Uri.parse("package:"+activity.getPackageName())));}
                catch(Exception e){status.setText("Не удалось открыть разрешение Android. Повторите установку позже; данные не изменены.");}
                finish();return;
            }
            status.setText("Повторно проверяем APK перед передачей установщику Android…");
            background(()->{
                File ready=UpdatePolicy.providerFile(activity.getCacheDir(),UpdatePolicy.URI,"r");
                if(apk==null || !ready.equals(apk))throw new IOException("no verified update");
                UpdateClient.verifyBytes(ready,manifest);AndroidUpdateVerifier.verify(activity,ready,manifest);
                return ()->{
                    if(!activity.hasWindowFocus()){status.setText("Вернитесь в ParanoID и снова нажмите «Установить». В фоне установщик не открывается.");return;}
                    String intentFailure;
                    try{
                        Uri uri=Uri.parse(UpdatePolicy.URI);
                        Intent install=new Intent(Intent.ACTION_INSTALL_PACKAGE).setDataAndType(uri,"application/vnd.android.package-archive");
                        install.setClipData(ClipData.newRawUri("Verified ParanoID update",uri));install.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                        // Prefer the system installer; some firmware hides it under MATCH_SYSTEM_ONLY,
                        // so fall back to the default resolver before declaring the installer unavailable.
                        ResolveInfo target=activity.getPackageManager().resolveActivity(install,PackageManager.MATCH_DEFAULT_ONLY|PackageManager.MATCH_SYSTEM_ONLY);
                        if(target==null || target.activityInfo==null)target=activity.getPackageManager().resolveActivity(install,PackageManager.MATCH_DEFAULT_ONLY);
                        if(target==null || target.activityInfo==null)throw new IOException("no activity resolves ACTION_INSTALL_PACKAGE");
                        install.setPackage(target.activityInfo.packageName);activity.startActivity(install);
                        status.setText("Открыт установщик Android — подтвердите обновление. Если отменили, можно нажать «Установить» снова. Установка ещё не подтверждена приложением.");
                        return;
                    }catch(Exception e){intentFailure=e.getClass().getSimpleName()+": "+String.valueOf(e.getMessage());}
                    // Owner report 2026-09-12 (twice, OPPO/ColorOS): the intent path failed although a
                    // sibling phone installed fine. Use the PackageInstaller session API, which does not
                    // depend on an installer activity being visible/resolvable. Same verified bytes.
                    try{
                        sessionInstall(ready);
                        status.setText("Установщик Android открыт через сессию — подтвердите обновление. Установка ещё не подтверждена приложением.");
                    }catch(Exception e){
                        status.setText("Установщик Android недоступен. Повторите позже; текущая версия и данные не изменены.\nДиагностика: intent — "+intentFailure+"; session — "+e.getClass().getSimpleName()+": "+String.valueOf(e.getMessage()));
                    }
                };
            });
        }
    }
    /** PackageInstaller session with the already re-verified file. The system asks the user to confirm; nothing installs silently. */
    private void sessionInstall(File ready)throws IOException {
        android.content.pm.PackageInstaller installer=activity.getPackageManager().getPackageInstaller();
        android.content.pm.PackageInstaller.SessionParams params=new android.content.pm.PackageInstaller.SessionParams(android.content.pm.PackageInstaller.SessionParams.MODE_FULL_INSTALL);
        params.setAppPackageName(activity.getPackageName());params.setSize(ready.length());
        int id=installer.createSession(params);
        android.content.pm.PackageInstaller.Session session=installer.openSession(id);
        try{
            try(OutputStream out=session.openWrite("verified.apk",0,ready.length());FileInputStream in=new FileInputStream(ready)){
                byte[] buffer=new byte[65536];int n;long total=0;
                while((n=in.read(buffer))>0){out.write(buffer,0,n);total+=n;}
                if(total!=ready.length())throw new IOException("short copy");
                session.fsync(out);
            }
            Intent result=new Intent(activity,MainActivity.class).setAction(INSTALL_STATUS).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
            int flags=PendingIntent.FLAG_UPDATE_CURRENT|(Build.VERSION.SDK_INT>=31?PendingIntent.FLAG_MUTABLE:0);
            session.commit(PendingIntent.getActivity(activity,54,result,flags).getIntentSender());
        }catch(IOException|RuntimeException failure){try{session.abandon();}catch(RuntimeException ignored){}throw failure;}
        finally{session.close();}
    }
    public static final String INSTALL_STATUS="global.paranoid.messenger.INSTALL_STATUS";
    /** Session callback delivered to MainActivity: launch the system confirmation when asked, otherwise show the outcome. */
    public static String installStatus(Activity activity,Intent intent){
        if(intent==null||!INSTALL_STATUS.equals(intent.getAction()))return null;
        int code=intent.getIntExtra(android.content.pm.PackageInstaller.EXTRA_STATUS,Integer.MIN_VALUE);
        if(code==android.content.pm.PackageInstaller.STATUS_PENDING_USER_ACTION){
            Intent confirm=intent.getParcelableExtra(Intent.EXTRA_INTENT);
            if(confirm!=null){try{activity.startActivity(confirm);}catch(RuntimeException e){return "Не удалось открыть подтверждение установки: "+e.getClass().getSimpleName();}}
            return "Подтвердите обновление в системном окне.";
        }
        if(code==android.content.pm.PackageInstaller.STATUS_SUCCESS)return "Обновление установлено.";
        return "Установка не выполнена ("+code+"): "+String.valueOf(intent.getStringExtra(android.content.pm.PackageInstaller.EXTRA_STATUS_MESSAGE))+". Текущая версия и данные не изменены.";
    }
}
