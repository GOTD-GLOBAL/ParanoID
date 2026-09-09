package org.paranoid.text;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.os.*;
import android.widget.Toast;

/** Opt-in foreground connection for this no-push alpha, never boot-started. */
public final class BackgroundConnectionService extends Service {
    public static final int NOTIFICATION_PERMISSION=94;
    private static final String CHANNEL="paranoid-connection",MESSAGES="paranoid-incoming",STOP="org.paranoid.devtext.STOP_CONNECTION";
    private static final int CONNECTION_ID=41,MESSAGE_ID=42;
    private static volatile boolean running;
    public static boolean running(){return running;}
    public static void requestStart(Activity activity) {
        if(Build.VERSION.SDK_INT>=33&&activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS},NOTIFICATION_PERMISSION);return;
        }
        try{activity.startForegroundService(new Intent(activity,BackgroundConnectionService.class));}
        catch(RuntimeException unavailable){Toast.makeText(activity,"Не удалось включить фоновое подключение. Откройте приложение и повторите.",Toast.LENGTH_LONG).show();}
    }
    public static void requestStop(Context context){context.stopService(new Intent(context,BackgroundConnectionService.class));}
    private static PendingIntent open(Context context) {
        return PendingIntent.getActivity(context,0,new Intent(context,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
    }
    @Override public int onStartCommand(Intent intent,int flags,int startId) {
        if(intent!=null&&STOP.equals(intent.getAction())){stopSelf();return START_NOT_STICKY;}
        NotificationManager manager=getSystemService(NotificationManager.class);
        if(Build.VERSION.SDK_INT>=33&&checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED){stopSelf();return START_NOT_STICKY;}
        NotificationChannel channel=new NotificationChannel(CHANNEL,"Фоновое подключение",NotificationManager.IMPORTANCE_LOW);
        channel.setDescription("Постоянное уведомление при включённом подключении ParanoID");channel.setShowBadge(false);manager.createNotificationChannel(channel);
        NotificationChannel incoming=new NotificationChannel(MESSAGES,"Новые сообщения",NotificationManager.IMPORTANCE_DEFAULT);
        incoming.setDescription("Без текста и имени отправителя");incoming.setLockscreenVisibility(Notification.VISIBILITY_PRIVATE);manager.createNotificationChannel(incoming);
        PendingIntent stop=PendingIntent.getService(this,1,new Intent(this,BackgroundConnectionService.class).setAction(STOP),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
        Notification notification=new Notification.Builder(this,CHANNEL).setSmallIcon(android.R.drawable.ic_dialog_email)
            .setContentTitle("ParanoID подключается в фоне").setContentText("Отключите, когда фоновое получение не нужно")
            .setContentIntent(open(this)).setOngoing(true).setOnlyAlertOnce(true).setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(new Notification.Action.Builder(null,"Отключить",stop).build()).build();
        try {
            if(Build.VERSION.SDK_INT>=34)startForeground(CONNECTION_ID,notification,android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
            else startForeground(CONNECTION_ID,notification);
            running=true;TextEngine.get(this).background(true);
        }catch(RuntimeException failure){stopSelf();}
        return START_NOT_STICKY;
    }
    /** Called only after new incoming plaintext has durably committed. */
    public static void incoming(Context context) {
        if(!running)return;
        try {
            Notification notification=new Notification.Builder(context,MESSAGES).setSmallIcon(android.R.drawable.ic_dialog_email)
                .setContentTitle("Новое сообщение в ParanoID").setContentText("Откройте приложение, чтобы прочитать")
                .setContentIntent(open(context)).setAutoCancel(true).setVisibility(Notification.VISIBILITY_PRIVATE).build();
            context.getSystemService(NotificationManager.class).notify(MESSAGE_ID,notification);
        }catch(RuntimeException ignored){/* Delivery persistence does not depend on notification permission. */}
    }
    @Override public void onDestroy(){running=false;TextEngine.get(this).background(false);stopForeground(STOP_FOREGROUND_REMOVE);super.onDestroy();}
    @Override public IBinder onBind(Intent intent){return null;}
}
