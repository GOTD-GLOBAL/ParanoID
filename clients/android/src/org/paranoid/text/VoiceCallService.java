package org.paranoid.text;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.os.*;

/** Microphone service starts only from a visible explicit call/answer action. */
public final class VoiceCallService extends Service {
    private static final String CHANNEL="paranoid-voice",INCOMING="paranoid-call-incoming",STOP="org.paranoid.devtext.END_CALL";
    private static final int ACTIVE_ID=51,INCOMING_ID=52;
    private static Runnable pending;
    private static boolean running;
    private String ownedCall="";
    public static void begin(Activity activity,Runnable ready){
        if(activity.isFinishing()||activity.isDestroyed()||activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED)return;
        if(running){ready.run();return;}
        pending=ready;
        try{activity.startForegroundService(new Intent(activity,VoiceCallService.class));}
        catch(RuntimeException error){pending=null;TextEngine.get(activity).calls().authorizationLost();android.widget.Toast.makeText(activity,"Не удалось начать звонок. Откройте приложение и повторите.",android.widget.Toast.LENGTH_LONG).show();}
    }
    public static void stop(Context context){pending=null;running=false;context.stopService(new Intent(context,VoiceCallService.class));}
    private static PendingIntent open(Context context){return PendingIntent.getActivity(context,51,new Intent(context,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);}
    public static void incoming(Context context){
        try{
            NotificationManager manager=context.getSystemService(NotificationManager.class);
            NotificationChannel channel=new NotificationChannel(INCOMING,"Входящие звонки",NotificationManager.IMPORTANCE_HIGH);
            channel.setDescription("Откройте ParanoID, чтобы ответить. Микрофон выключен.");channel.setLockscreenVisibility(Notification.VISIBILITY_PRIVATE);manager.createNotificationChannel(channel);
            manager.notify(INCOMING_ID,new Notification.Builder(context,INCOMING).setSmallIcon(android.R.drawable.sym_call_incoming)
                .setContentTitle("Входящий звонок ParanoID").setContentText("Откройте приложение, чтобы ответить")
                .setCategory(Notification.CATEGORY_CALL).setContentIntent(open(context)).setAutoCancel(true).setVisibility(Notification.VISIBILITY_PRIVATE).build());
        }catch(RuntimeException ignored){/* Never grant microphone access from a notification failure. */}
    }
    public static void clearIncoming(Context context){context.getSystemService(NotificationManager.class).cancel(INCOMING_ID);}
    @Override public int onStartCommand(Intent intent,int flags,int startId){
        if(intent!=null&&STOP.equals(intent.getAction())){
            CallController calls=TextEngine.get(this).calls();org.json.JSONObject view=calls.snapshot();
            if(calls.active()&&view.optString("call_id").equals(intent.getStringExtra("call_id"))&&view.optLong("generation")==intent.getLongExtra("generation",-1)){calls.hangup();stopSelf();}
            else if(!calls.active())stopSelf();
            return START_NOT_STICKY;
        }
        if(pending==null&&!running){stopSelf();return START_NOT_STICKY;}
        if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED){pending=null;stopSelf();return START_NOT_STICKY;}
        NotificationManager manager=getSystemService(NotificationManager.class);
        NotificationChannel channel=new NotificationChannel(CHANNEL,"Текущий звонок",NotificationManager.IMPORTANCE_LOW);channel.setShowBadge(false);manager.createNotificationChannel(channel);
        Notification notification=new Notification.Builder(this,CHANNEL).setSmallIcon(android.R.drawable.sym_call_outgoing)
            .setContentTitle("Аудиозвонок ParanoID").setContentText("Нажмите, чтобы вернуться к звонку")
            .setContentIntent(open(this)).setOngoing(true).setOnlyAlertOnce(true).setCategory(Notification.CATEGORY_CALL).setVisibility(Notification.VISIBILITY_PRIVATE).build();
        try{
            if(Build.VERSION.SDK_INT>=34)startForeground(ACTIVE_ID,notification,android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE);
            else startForeground(ACTIVE_ID,notification);
            running=true;Runnable action=pending;pending=null;if(action!=null)action.run();ownedCall=TextEngine.get(this).calls().snapshot().optString("call_id");
            if(!TextEngine.get(this).calls().active())stopSelf();
            else {
                long generation=TextEngine.get(this).calls().snapshot().optLong("generation");
                Intent end=new Intent(this,VoiceCallService.class).setAction(STOP).setData(android.net.Uri.parse("paranoid-call-end:"+ownedCall))
                    .putExtra("call_id",ownedCall).putExtra("generation",generation);
                PendingIntent stop=PendingIntent.getService(this,52,end,PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
                manager.notify(ACTIVE_ID,new Notification.Builder(this,CHANNEL).setSmallIcon(android.R.drawable.sym_call_outgoing)
                    .setContentTitle("Аудиозвонок ParanoID").setContentText("Нажмите, чтобы вернуться к звонку")
                    .setContentIntent(open(this)).setOngoing(true).setOnlyAlertOnce(true).setCategory(Notification.CATEGORY_CALL).setVisibility(Notification.VISIBILITY_PRIVATE)
                    .addAction(new Notification.Action.Builder(null,"Завершить",stop).build()).build());
            }
        }catch(RuntimeException error){pending=null;TextEngine.get(this).calls().authorizationLost();stopSelf();}
        return START_NOT_STICKY;
    }
    @Override public void onDestroy(){
        running=false;CallController calls=TextEngine.get(this).calls();
        if(calls.active()&&calls.snapshot().optString("call_id").equals(ownedCall))calls.authorizationLost();
        stopForeground(STOP_FOREGROUND_REMOVE);super.onDestroy();
    }
    @Override public IBinder onBind(Intent intent){return null;}
}
