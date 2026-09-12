package org.paranoid.text;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioManager;
import android.media.MediaPlayer;
import android.media.RingtoneManager;
import android.media.ToneGenerator;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;
import org.json.JSONObject;

/**
 * Audible call progress, driven only by the authenticated CallController state on the main thread:
 * incoming ring (system ringtone + vibration, respects the ringer mode), outgoing ringback while the
 * peer's phone rings, and a short busy tone when an outgoing call ends unanswered.
 * Owner request 2026-09-12. Nothing here touches microphone, camera or media authority.
 */
public final class CallTones {
    private static final long MAX_RING_MS=60_000, BUSY_MS=2_000;
    private static final long[] VIBRATION={0,700,900};
    private final Context context;
    private final Handler main=new Handler(Looper.getMainLooper());
    private MediaPlayer ringtone;
    private ToneGenerator ringback,busy;
    private Vibrator vibrator;
    private String state="idle",callId="";
    private boolean outgoing;
    private final Runnable ringLimit=this::stopIncoming;
    private final Runnable busyLimit=this::stopBusy;
    public CallTones(Context context){this.context=context.getApplicationContext();}

    /** Apply the controller snapshot; idempotent per state transition. */
    public void changed(JSONObject view){
        String next=view.optString("state","idle"),id=view.optString("call_id");
        if(next.equals(state)&&id.equals(callId))return;
        boolean wasOutgoingRinging=state.equals("outgoing")&&outgoing;
        if(next.equals("starting"))outgoing=true;
        else if(next.equals("incoming"))outgoing=false;
        state=next;callId=id;
        if(next.equals("incoming"))startIncoming();else stopIncoming();
        if(next.equals("outgoing")&&outgoing)startRingback();else stopRingback();
        String reason=view.optString("reason");
        if(next.equals("ended")&&wasOutgoingRinging&&(reason.equals("busy")||reason.equals("reject")||reason.equals("timeout")))startBusy();
        else if(!next.equals("ended"))stopBusy();
        if(next.equals("idle")||next.equals("ended")){outgoing=false;}
    }
    public void release(){stopIncoming();stopRingback();stopBusy();}

    private void startIncoming(){
        if(ringtone!=null||vibrator!=null&&vibrator.hasVibrator())return;
        AudioManager audio=(AudioManager)context.getSystemService(Context.AUDIO_SERVICE);
        int mode=audio==null?AudioManager.RINGER_MODE_NORMAL:audio.getRingerMode();
        if(mode!=AudioManager.RINGER_MODE_SILENT){
            try{
                Vibrator v=(Vibrator)context.getSystemService(Context.VIBRATOR_SERVICE);
                if(v!=null&&v.hasVibrator()){
                    v.vibrate(VibrationEffect.createWaveform(VIBRATION,0),new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build());
                    vibrator=v;
                }
            }catch(RuntimeException ignored){vibrator=null;}
        }
        if(mode==AudioManager.RINGER_MODE_NORMAL){
            try{
                Uri uri=RingtoneManager.getActualDefaultRingtoneUri(context,RingtoneManager.TYPE_RINGTONE);
                if(uri==null)uri=RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE);
                MediaPlayer player=new MediaPlayer();
                player.setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build());
                player.setDataSource(context,uri);player.setLooping(true);player.prepare();player.start();
                ringtone=player;
            }catch(Exception failure){
                closeRingtone();
                // No usable system ringtone (e.g. restricted storage): fall back to a synthesized ring.
                try{ringback=new ToneGenerator(AudioManager.STREAM_RING,ToneGenerator.MAX_VOLUME);ringback.startTone(ToneGenerator.TONE_SUP_RINGTONE);}
                catch(RuntimeException ignored){ringback=null;}
            }
        }
        main.removeCallbacks(ringLimit);main.postDelayed(ringLimit,MAX_RING_MS);
    }
    private void stopIncoming(){
        main.removeCallbacks(ringLimit);
        closeRingtone();
        if(vibrator!=null){try{vibrator.cancel();}catch(RuntimeException ignored){}vibrator=null;}
        if(!state.equals("outgoing"))stopRingback();
    }
    private void closeRingtone(){
        if(ringtone==null)return;
        try{if(ringtone.isPlaying())ringtone.stop();}catch(RuntimeException ignored){}
        try{ringtone.release();}catch(RuntimeException ignored){}
        ringtone=null;
    }
    private void startRingback(){
        if(ringback!=null)return;
        // Voice-call stream: follows the current route (earpiece/speaker/headset) chosen by the media engine.
        try{ringback=new ToneGenerator(AudioManager.STREAM_VOICE_CALL,ToneGenerator.MAX_VOLUME*7/10);ringback.startTone(ToneGenerator.TONE_SUP_RINGTONE);}
        catch(RuntimeException ignored){ringback=null;}
    }
    private void stopRingback(){
        if(ringback==null)return;
        try{ringback.stopTone();}catch(RuntimeException ignored){}
        try{ringback.release();}catch(RuntimeException ignored){}
        ringback=null;
    }
    private void startBusy(){
        stopBusy();
        try{busy=new ToneGenerator(AudioManager.STREAM_VOICE_CALL,ToneGenerator.MAX_VOLUME*7/10);busy.startTone(ToneGenerator.TONE_SUP_BUSY,(int)BUSY_MS);}
        catch(RuntimeException ignored){busy=null;return;}
        main.postDelayed(busyLimit,BUSY_MS+200);
    }
    private void stopBusy(){
        main.removeCallbacks(busyLimit);
        if(busy==null)return;
        try{busy.stopTone();}catch(RuntimeException ignored){}
        try{busy.release();}catch(RuntimeException ignored){}
        busy=null;
    }
}
