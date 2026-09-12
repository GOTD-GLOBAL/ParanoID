package org.paranoid.text;

import com.google.firebase.messaging.FirebaseMessaging;
import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;

/**
 * RFC-0020 push wake. Google delivers only {"t":"wake"} (no content, no sender); on receipt we
 * reconnect the authenticated realtime loop so the real message/call arrives over the pinned
 * E2EE channel. The token is registered with the server over the signed session; nothing else.
 */
public final class PushService extends FirebaseMessagingService {
    @Override public void onNewToken(String token){TextEngine.get(this).pushToken(token);}
    @Override public void onMessageReceived(RemoteMessage message){
        if(!"wake".equals(message.getData().get("t")))return;
        TextEngine.get(this).pushWake();
    }
    /** Ask Firebase for the current token; the engine registers it once a signed session exists. */
    static void requestToken(TextEngine engine){
        try{FirebaseMessaging.getInstance().getToken().addOnCompleteListener(task->{if(task.isSuccessful()&&task.getResult()!=null)engine.pushToken(task.getResult());});}
        catch(RuntimeException unavailable){/* No Google services on this device: foreground channel only. */}
    }
}
