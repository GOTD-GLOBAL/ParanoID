package org.paranoid.text;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.SystemClock;

/**
 * AlarmManager-сторож фонового канала: неточный повторяющийся будильник (~15 минут)
 * перезапускает BackgroundConnectionService, если прошивка (например, OPPO) убила его.
 * Взводится только после явного включения фона пользователем и снимается при его
 * выключении; никогда не стартует с загрузки устройства (никакого boot-приёмника)
 * и не требует SCHEDULE_EXACT_ALARM — точность здесь не нужна.
 */
public final class ConnectionWatchdog extends BroadcastReceiver {
    private static final String PREFS="paranoid-ui",ENABLED_KEY="background_enabled_v1";
    private static final long INTERVAL=15*60*1000L;
    private static final int REQUEST=2;

    /** Persisted opt-in: true only between explicit user enable and explicit user disable. */
    public static boolean enabled(Context context) {
        return context.getSharedPreferences(PREFS,Context.MODE_PRIVATE).getBoolean(ENABLED_KEY,false);
    }
    static void enable(Context context) {
        context.getSharedPreferences(PREFS,Context.MODE_PRIVATE).edit().putBoolean(ENABLED_KEY,true).apply();
        AlarmManager alarms=context.getSystemService(AlarmManager.class);
        if(alarms==null)return;
        alarms.setInexactRepeating(AlarmManager.ELAPSED_REALTIME_WAKEUP,
            SystemClock.elapsedRealtime()+INTERVAL,INTERVAL,operation(context));
    }
    static void disable(Context context) {
        context.getSharedPreferences(PREFS,Context.MODE_PRIVATE).edit().putBoolean(ENABLED_KEY,false).apply();
        AlarmManager alarms=context.getSystemService(AlarmManager.class);
        if(alarms!=null)alarms.cancel(operation(context));
    }
    private static PendingIntent operation(Context context) {
        return PendingIntent.getBroadcast(context,REQUEST,new Intent(context,ConnectionWatchdog.class),
            PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
    }
    @Override public void onReceive(Context context,Intent intent) {
        if(!enabled(context)||BackgroundConnectionService.running())return;
        // На SDK>=31 старт FGS из будильника может быть запрещён
        // (ForegroundServiceStartNotAllowedException/SecurityException — обе RuntimeException):
        // молча пропускаем, следующая попытка через ~15 минут.
        try{context.startForegroundService(new Intent(context,BackgroundConnectionService.class));}
        catch(RuntimeException notAllowed){/* следующая попытка по будильнику */}
    }
}
