package org.paranoid.text;

import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayDeque;
import java.util.HashMap;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

/**
 * Call-v2 runtime authority (audio call with optional camera video). All methods and Port completions belong to one
 * owner (Android's main handler). No call authority is loaded from storage.
 * Input events must come from the native authenticated, committed receive path.
 */
public final class CallController {
    public interface Clock { long wallMillis(); long monotonicMillis(); }
    /** true means durable local commit AND validated server acceptance. */
    public interface Completion { void done(boolean accepted); }
    public interface Port {
        void send(String account, JSONObject body, Completion completion);
        void mediaOffer(long generation);
        void mediaAnswer(long generation, String remoteSdp);
        void mediaRemoteAnswer(long generation, String remoteSdp);
        void mediaMute(boolean muted);
        void mediaSpeaker(boolean speaker);
        /** Local camera on/off; only ever called after explicit user video intent + permission. */
        void mediaVideo(boolean enabled);
        void mediaClose();
        void changed(JSONObject publicView);
        /**
         * One call ended, with the facts the public view cannot carry: the direction it was placed
         * in and how long it was actually connected. Called on the owner thread, once per call,
         * immediately after the terminal view is published. Ignoring it is the default, because a
         * call log is a screen's business and not the protocol's.
         */
        default void finished(JSONObject termination){}
    }
    private static final long TTL=45_000, HEARTBEAT=10_000, SILENCE=30_000,
        DISCONNECTED=10_000, MAX_CALL=900_000, CLOCK_SKEW=5_000;
    private static final int MAX_READY=8, MAX_TERMINALS=64, MAX_SDP=12288;
    private static final String[] FIELDS={"v","kind","call_id","caller_nonce","callee_nonce",
        "seq","sent_ms","expires_ms","sdp","fingerprint","ice_ufrag","ice_pwd","offer_digest","reason","video"};
    private final Clock clock;
    private final Port port;
    private final SecureRandom random=new SecureRandom();
    private final Map<String,Slot> ready=new HashMap<>();
    private final Map<String,Long> terminals=new LinkedHashMap<>();
    private final Map<String,ArrayDeque<Long>> peerKnocks=new HashMap<>();
    private final ArrayDeque<Long> globalKnocks=new ArrayDeque<>();
    private final Thread owner=Thread.currentThread();
    private long generation, lastWall, lastMono, terminalOverflowUntil;
    private boolean online;
    private Call call;
    private String state="idle", reason="", lastAccount="", lastCallId="";

    private static class Slot {
        String account,id,caller,callee;
        long deadline;
        Slot(String account,String id,String caller,String callee,long deadline){
            this.account=account;this.id=id;this.caller=caller;this.callee=callee;this.deadline=deadline;
        }
    }
    private static final class Call extends Slot {
        final boolean outgoing;
        final long generation,started;
        String offerDigest="",remoteSdp="";
        int nextSequence=2,remoteSequence=-1;
        boolean media,muted,speaker,heartbeatPending,answerKnown,descriptionSent;
        /** localVideo: user turned own camera on; remoteVideo: peer's last authenticated media control. */
        boolean localVideo,remoteVideo,videoIntent,speakerBeforeVideo;
        long heartbeatSent,heartbeatReceived,disconnectedAt=-1,connectedAt=-1;
        Call(Slot slot,boolean outgoing,long generation,long now){
            super(slot.account,slot.id,slot.caller,slot.callee,slot.deadline);
            this.outgoing=outgoing;this.generation=generation;this.started=now;
        }
    }
    public CallController(Clock clock,Port port){
        this.clock=clock;this.port=port;lastWall=clock.wallMillis();lastMono=clock.monotonicMillis();
    }
    private void own(){if(Thread.currentThread()!=owner)throw new IllegalStateException("call owner thread");}
    public boolean active(){own();return call!=null;}
    public boolean connected(){own();return online;}
    /** Public presentation only: no SDP, ICE passwords, or nonce capabilities. */
    public JSONObject snapshot(){
        own();Call c=call;long elapsed=c==null||c.connectedAt<0?0:Math.max(0,clock.monotonicMillis()-c.connectedAt);
        try{return new JSONObject().put("state",state).put("account",c==null?lastAccount:c.account)
            .put("call_id",c==null?lastCallId:c.id).put("generation",generation)
            .put("muted",c!=null&&c.muted).put("speaker",c!=null&&c.speaker)
            .put("reconnecting",c!=null&&c.disconnectedAt>=0)
            .put("reason",reason).put("media_active",c!=null&&c.media).put("elapsed_ms",elapsed)
            .put("local_video",c!=null&&c.localVideo).put("remote_video",c!=null&&c.remoteVideo);
        }catch(Exception failure){throw new IllegalStateException("call view",failure);}
    }
    private void publish(){port.changed(snapshot());}
    public void connection(boolean connected){own();online=connected;}

    public void start(String account,boolean microphonePermission){start(account,microphonePermission,false);}
    /** videoIntent requests the camera immediately after media authority; it never bypasses CAMERA permission (port decides). */
    public void start(String account,boolean microphonePermission,boolean videoIntent){
        own();if(!checkClock())return;purge();
        if(call!=null)return;
        if(!microphonePermission||!online||!hex(account,64)||!terminalRoom()){
            lastAccount=account==null?"":account;state="ended";reason=microphonePermission?"unavailable":"reject";publish();return;
        }
        long now=clock.monotonicMillis();Slot slot=new Slot(account,UUID.randomUUID().toString(),nonce(),"",now+TTL);
        call=new Call(slot,true,++generation,now);call.videoIntent=videoIntent;state="starting";reason="";publish();
        sendActive(body(call,"knock",0,"","","","",""),false);
    }
    public void answer(boolean microphonePermission){
        own();if(!checkClock())return;
        Call c=call;if(c==null||!state.equals("incoming"))return;
        if(!microphonePermission||!online){finish(microphonePermission?"unavailable":"reject",true);return;}
        if(expired(c)){finish("timeout",true);return;}
        state="authorizing";
        publish();
        try{port.mediaAnswer(c.generation,c.remoteSdp);applyRoutes(c);}catch(RuntimeException failure){finish("failed",true);}
    }
    public void reject(){own();if(call!=null)finish("reject",true);}
    public void hangup(){own();if(call!=null)finish(call.outgoing&&!call.answerKnown?"cancel":"hangup",true);}
    public void authorizationLost(){own();online=false;ready.clear();if(call!=null)finish("unavailable",false);}
    public void block(String account){
        own();for(Iterator<Slot> it=ready.values().iterator();it.hasNext();)if(it.next().account.equals(account))it.remove();
        if(call!=null&&call.account.equals(account))finish("unavailable",false);
    }
    public void mute(boolean muted){
        own();if(call!=null)try{call.muted=muted;if(call.media)port.mediaMute(muted);publish();}
        catch(RuntimeException failure){finish("failed",true);}
    }
    public void speaker(boolean speaker){
        own();if(call!=null)try{call.speaker=speaker;if(call.media)port.mediaSpeaker(speaker);publish();}
        catch(RuntimeException failure){finish("failed",true);}
    }
    /** Explicit user camera toggle. Owner decision 2026-09-11: video on -> speaker unless a headset is active (port resolves headset); video off restores the previous route. */
    public void video(boolean enabled){
        own();Call c=call;if(c==null||!c.media||c.localVideo==enabled)return;
        try{port.mediaVideo(enabled);}
        catch(SecurityException denied){publish();return;/* No permission: stay audio-only. */}
        catch(RuntimeException failure){finish("failed",true);return;}
        try{
            if(enabled){c.speakerBeforeVideo=c.speaker;c.speaker=true;}else c.speaker=c.speakerBeforeVideo;
            c.localVideo=enabled;port.mediaSpeaker(c.speaker);
            if(c.descriptionSent&&(state.equals("connecting")||state.equals("connected")))sendActive(body(c,"media",c.nextSequence++,"","","","",""),false);
            publish();
        }catch(RuntimeException failure){finish("failed",true);}
    }
    /** Called by the media owner once the engine for this generation exists: applies a pending explicit video-call intent. */
    public void mediaReady(long callbackGeneration){
        own();Call c=call;if(c==null||c.generation!=callbackGeneration||!c.media||!c.videoIntent)return;
        c.videoIntent=false;video(true);
    }
    /** Engine reported the camera cannot run: revert to audio, tell the peer, keep the call. */
    public void videoUnavailable(long callbackGeneration){
        own();Call c=call;if(c==null||c.generation!=callbackGeneration||!c.localVideo)return;
        c.localVideo=false;c.speaker=c.speakerBeforeVideo;
        try{port.mediaVideo(false);}catch(RuntimeException ignored){/* engine already stopped capture */}
        try{port.mediaSpeaker(c.speaker);}catch(RuntimeException ignored){/* route restore is best effort */}
        if(c.descriptionSent&&(state.equals("connecting")||state.equals("connected")))sendActive(body(c,"media",c.nextSequence++,"","","","",""),false);
        publish();
    }
    private void applyRoutes(Call c){port.mediaMute(c.muted);port.mediaSpeaker(c.speaker);}

    public void received(JSONObject event){
        own();if(!checkClock())return;purge();
        try{
            String account=event.getString("account");JSONObject b=event.getJSONObject("body");
            if(!hex(account,64)||!valid(b))return;
            String kind=b.getString("kind"),id=b.getString("call_id");
            if(terminals.containsKey(key(account,id))||clock.monotonicMillis()<terminalOverflowUntil)return;
            if(kind.equals("knock")){knock(account,b);return;}
            if(kind.equals("offer")){offer(account,b);return;}
            if(kind.equals("end")&&endReadiness(account,b))return;
            Call c=call;if(c==null||!baseContext(c,account,b))return;
            int seq=b.getInt("seq");
            if(kind.equals("ready")){
                if(!c.outgoing||!state.equals("starting")||seq!=0||!c.callee.isEmpty()||expired(c))return;
                c.callee=b.getString("callee_nonce");c.remoteSequence=0;state="authorizing";publish();
                try{port.mediaOffer(c.generation);applyRoutes(c);}catch(RuntimeException failure){finish("failed",true);}return;
            }
            if(!c.callee.equals(b.getString("callee_nonce"))||seq<=c.remoteSequence)return;
            if(!c.offerDigest.equals(b.getString("offer_digest")))return;
            if(kind.equals("end")){c.remoteSequence=seq;finish(b.getString("reason"),false);return;}
            if(kind.equals("answer")){
                if(!c.outgoing||!state.equals("outgoing")||!c.descriptionSent||c.offerDigest.isEmpty()||seq!=1||expired(c))return;
                c.remoteSequence=seq;c.answerKnown=true;state="connecting";
                c.heartbeatReceived=clock.monotonicMillis();c.heartbeatSent=c.heartbeatReceived;publish();
                try{port.mediaRemoteAnswer(c.generation,b.getString("sdp"));}catch(RuntimeException failure){finish("failed",true);return;}
                if(c.localVideo)sendActive(body(c,"media",c.nextSequence++,"","","","",""),false);
                return;
            }
            if(kind.equals("heartbeat")&&(state.equals("connecting")||state.equals("connected"))&&seq>=2){
                c.remoteSequence=seq;c.heartbeatReceived=clock.monotonicMillis();
            }
            if(kind.equals("media")&&(state.equals("connecting")||state.equals("connected"))&&seq>=2){
                // Informative only: the UI states what the peer claims; actual frames come from the engine.
                c.remoteSequence=seq;c.heartbeatReceived=clock.monotonicMillis();c.remoteVideo=b.getBoolean("video");publish();
            }
        }catch(Exception invalid){/* Invalid input cannot grant UI or media authority. */}
    }
    private void knock(String account,JSONObject b)throws Exception{
        // Authenticated durable-delivered knocks are not gated on the transient
        // online flag: replying "ready" goes through the durable outbox anyway.
        if(!allowKnock(account)||!terminalRoom())return;
        if(call!=null){sendDetached(account,b,"","","busy");return;}
        for(Slot s:ready.values())if(s.account.equals(account))return;
        if(ready.size()>=MAX_READY)return;
        String k=key(account,b.getString("call_id"));Slot slot=new Slot(account,b.getString("call_id"),b.getString("caller_nonce"),nonce(),deadline(b));
        ready.put(k,slot);
        JSONObject response=body(slot,"ready",0,"","","","","");
        try{port.send(account,response,accepted->{own();if(!accepted&&ready.get(k)==slot)ready.remove(k);});}
        catch(RuntimeException failure){ready.remove(k);}
    }
    private void offer(String account,JSONObject b)throws Exception{
        Slot slot=ready.get(key(account,b.getString("call_id")));
        if(slot==null||expired(slot)||!baseContext(slot,account,b)||!slot.callee.equals(b.getString("callee_nonce"))||b.getInt("seq")!=1)return;
        if(!digest(b.getString("sdp")).equals(b.getString("offer_digest")))return;
        ready.remove(key(account,slot.id));
        if(call!=null||!online||!terminalRoom()){
            sendDetached(account,b,slot.callee,b.getString("offer_digest"),"busy");remember(account,slot.id);return;
        }
        slot.deadline=Math.min(slot.deadline,deadline(b));call=new Call(slot,false,++generation,clock.monotonicMillis());
        call.offerDigest=b.getString("offer_digest");call.remoteSdp=b.getString("sdp");call.remoteSequence=1;
        state="incoming";reason="";publish();
    }
    private boolean endReadiness(String account,JSONObject b)throws Exception{
        Slot slot=ready.get(key(account,b.getString("call_id")));
        if(slot==null||!baseContext(slot,account,b)||!b.getString("offer_digest").isEmpty())return false;
        // The caller may cancel while our ready response is still in flight.
        // This releases only a readiness slot; active calls remain strict above.
        String callee=b.getString("callee_nonce");
        if(!callee.isEmpty()&&!slot.callee.equals(callee))return false;
        ready.remove(key(account,slot.id));remember(account,slot.id);return true;
    }
    private static boolean baseContext(Slot s,String account,JSONObject b)throws Exception{
        return s.account.equals(account)&&s.id.equals(b.getString("call_id"))&&s.caller.equals(b.getString("caller_nonce"));
    }

    /** A current validated issuer response or disclosed legacy capability permits media. */
    public boolean mediaAuthorized(long callbackGeneration,boolean authorized){
        own();if(!checkClock())return false;
        Call c=call;if(c==null||c.generation!=callbackGeneration||!state.equals("authorizing"))return false;
        if(!authorized||!online||expired(c)){finish(expired(c)?"timeout":"failed",true);return false;}
        c.media=true;state=c.outgoing?"outgoing":"connecting";
        c.heartbeatReceived=clock.monotonicMillis();c.heartbeatSent=c.heartbeatReceived;
        try{applyRoutes(c);publish();return true;}catch(RuntimeException failure){finish("failed",true);return false;}
    }

    /** Called only with the exact gathered local SDP and its parsed parameters. */
    public void localDescription(long callbackGeneration,String sdp,String fingerprint,String ufrag,String password){
        own();if(!checkClock())return;
        Call c=call;if(c==null||c.generation!=callbackGeneration||c.descriptionSent)return;
        if(expired(c)){finish("timeout",true);return;}
        if(sdp==null||sdp.isEmpty()||sdp.getBytes(StandardCharsets.UTF_8).length>MAX_SDP||!hex(fingerprint,64)||!ice(ufrag,4,256)||!ice(password,22,256)){
            finish("failed",true);return;
        }
        String kind;
        if(c.outgoing&&state.equals("outgoing")){kind="offer";c.offerDigest=digest(sdp);}
        else if(!c.outgoing&&state.equals("connecting")){kind="answer";c.answerKnown=true;}
        else return;
        c.descriptionSent=true;
        sendActive(body(c,kind,1,sdp,fingerprint,ufrag,password,""),false);
        // Callee: a camera toggled during Answer negotiation is announced only after its own answer (seq 1).
        if(kind.equals("answer")&&c.localVideo)sendActive(body(c,"media",c.nextSequence++,"","","","",""),false);
        publish();
    }
    public void mediaState(long callbackGeneration,String mediaState){
        own();if(!checkClock())return;
        Call c=call;if(c==null||c.generation!=callbackGeneration||!c.media)return;
        long now=clock.monotonicMillis();
        if(mediaState.equals("connected")){
            if(!c.answerKnown||!c.descriptionSent&& !c.outgoing)return;
            if(!state.equals("connecting")&&!state.equals("connected"))return;
            c.disconnectedAt=-1;if(c.connectedAt<0)c.connectedAt=now;state="connected";publish();
        }else if(mediaState.equals("disconnected")){
            if(c.disconnectedAt<0)c.disconnectedAt=now;publish();
        }else if(mediaState.equals("failed")||mediaState.equals("closed")){finish("failed",true);}
    }
    public void tick(){
        own();if(!checkClock())return;purge();Call c=call;if(c==null)return;
        long now=clock.monotonicMillis();
        if(now-c.started>=MAX_CALL||(!state.equals("connected")&&expired(c))){finish("timeout",true);return;}
        if(c.disconnectedAt>=0&&now-c.disconnectedAt>=DISCONNECTED){finish("failed",true);return;}
        if(state.equals("connecting")||state.equals("connected")){
            if(now-c.heartbeatReceived>=SILENCE){finish("timeout",true);return;}
            if(online&&!c.heartbeatPending&&now-c.heartbeatSent>=HEARTBEAT){
                c.heartbeatSent=now;c.heartbeatPending=true;
                sendActive(body(c,"heartbeat",c.nextSequence++,"","","","",""),true);
            }
        }
        if(call!=null)publish();
    }
    private void sendActive(JSONObject body,boolean heartbeat){
        Call c=call;if(c==null)return;
        // A transient offline flag must not end an active call: sends are
        // durable-outboxed and the call is bounded by heartbeat/TTL timeouts.
        try{port.send(c.account,body,accepted->{
            own();if(call!=c)return;
            if(!accepted){finish("failed",false);return;}
            if(heartbeat)c.heartbeatPending=false;
        });}catch(RuntimeException failure){if(call==c)finish("failed",false);}
    }
    private void sendDetached(String account,JSONObject input,String callee,String offerDigest,String endReason)throws Exception{
        if(!online)return;
        Slot s=new Slot(account,input.getString("call_id"),input.getString("caller_nonce"),callee,clock.monotonicMillis()+TTL);
        JSONObject end=body(s,"end",2,"","","","",endReason).put("offer_digest",offerDigest);
        try{port.send(account,end,accepted->{own();});}catch(RuntimeException ignored){/* No new local media authority. */}
    }
    private void finish(String endReason,boolean tellPeer){
        Call c=call;if(c==null)return;
        JSONObject end=tellPeer&&online?body(c,"end",c.nextSequence++,"","","","",endReason):null;
        // Read while the call is still here: `call` is cleared on the next line and the published
        // view then reports zero seconds for every call that ever connected (snapshot()).
        JSONObject termination=termination(c,endReason);
        call=null;generation++;lastAccount=c.account;lastCallId=c.id;state="ended";reason=endReason;
        remember(c.account,c.id);
        try{port.mediaClose();}finally{publish();port.finished(termination);}
        if(end!=null)try{port.send(c.account,end,accepted->{own();});}catch(RuntimeException ignored){/* Terminal already applied. */}
    }
    /** The terminal facts of one call: direction, whether media ever connected, and for how long. */
    private JSONObject termination(Call c,String endReason){
        long seconds=c.connectedAt<0?0:Math.max(0,(clock.monotonicMillis()-c.connectedAt)/1000);
        try{return new JSONObject().put("call_id",c.id).put("account",c.account).put("outgoing",c.outgoing)
            .put("connected",c.connectedAt>=0).put("video",c.localVideo||c.remoteVideo)
            .put("duration_seconds",seconds).put("reason",endReason);
        }catch(Exception failure){throw new IllegalStateException("call termination",failure);}
    }
    private JSONObject body(Slot s,String kind,int seq,String sdp,String fp,String ufrag,String pwd,String endReason){
        long wall=clock.wallMillis();
        boolean video=kind.equals("media")?s instanceof Call&&((Call)s).localVideo:(kind.equals("knock")||kind.equals("ready")||kind.equals("offer")||kind.equals("answer"));
        try{return new JSONObject().put("v",2).put("kind",kind).put("call_id",s.id).put("video",video)
            .put("caller_nonce",s.caller).put("callee_nonce",s.callee).put("seq",seq)
            .put("sent_ms",wall).put("expires_ms",Math.addExact(wall,TTL)).put("sdp",sdp)
            .put("fingerprint",fp).put("ice_ufrag",ufrag).put("ice_pwd",pwd)
            .put("offer_digest",s instanceof Call?((Call)s).offerDigest:"").put("reason",endReason);
        }catch(Exception failure){throw new IllegalStateException("call control",failure);}
    }
    private boolean valid(JSONObject b)throws Exception{
        if(b.length()!=FIELDS.length)return false;for(String f:FIELDS)if(!b.has(f)||b.isNull(f))return false;
        if(!number(b,"v")||b.getInt("v")!=2||!number(b,"seq")||b.getLong("seq")<0||b.getLong("seq")>Integer.MAX_VALUE||!number(b,"sent_ms")||!number(b,"expires_ms"))return false;
        if(!(b.get("video") instanceof Boolean))return false;
        for(String f:FIELDS)if(!f.equals("v")&&!f.equals("seq")&&!f.equals("sent_ms")&&!f.equals("expires_ms")&&!f.equals("video")&&!(b.get(f) instanceof String))return false;
        long sent=b.getLong("sent_ms"),expires=b.getLong("expires_ms"),wall=clock.wallMillis();
        if(sent<=0||expires<=sent||expires-sent>TTL||wall>=expires||sent-wall>CLOCK_SKEW)return false;
        if(!b.getString("call_id").matches("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")||!hex(b.getString("caller_nonce"),64))return false;
        String kind=b.getString("kind"),callee=b.getString("callee_nonce"),sdp=b.getString("sdp"),od=b.getString("offer_digest"),r=b.getString("reason");
        int seq=b.getInt("seq");
        if(!callee.isEmpty()&&!hex(callee,64))return false;
        boolean description=kind.equals("offer")||kind.equals("answer");
        if(description){
            if(seq!=1||callee.isEmpty()||sdp.isEmpty()||sdp.getBytes(StandardCharsets.UTF_8).length>MAX_SDP||!hex(od,64)||!hex(b.getString("fingerprint"),64)||!ice(b.getString("ice_ufrag"),4,256)||!ice(b.getString("ice_pwd"),22,256)||!r.isEmpty())return false;
        }else{
            if(!sdp.isEmpty()||!b.getString("fingerprint").isEmpty()||!b.getString("ice_ufrag").isEmpty()||!b.getString("ice_pwd").isEmpty())return false;
            if(kind.equals("knock"))return seq==0&&callee.isEmpty()&&od.isEmpty()&&r.isEmpty();
            if(kind.equals("ready"))return seq==0&&!callee.isEmpty()&&od.isEmpty()&&r.isEmpty();
            if(kind.equals("heartbeat"))return seq>=2&&!callee.isEmpty()&&hex(od,64)&&r.isEmpty()&&!b.getBoolean("video");
            if(kind.equals("media"))return seq>=2&&!callee.isEmpty()&&hex(od,64)&&r.isEmpty();
            if(kind.equals("end"))return seq>=2&&(od.isEmpty()||hex(od,64))&&r.matches("hangup|reject|cancel|busy|timeout|failed|unavailable")&&!b.getBoolean("video");
            return false;
        }
        return true;
    }
    private static boolean number(JSONObject b,String field)throws Exception{Object n=b.get(field);return n instanceof Integer||n instanceof Long;}
    private boolean checkClock(){
        long mono=clock.monotonicMillis(),wall=clock.wallMillis();
        long delta=mono-lastMono,wallDelta=wall-lastWall;lastMono=mono;lastWall=wall;
        if(delta<0||wall<=0||Math.abs(wallDelta-delta)>CLOCK_SKEW){ready.clear();if(call!=null)finish("failed",false);return false;}return true;
    }
    private long deadline(JSONObject b)throws Exception{return clock.monotonicMillis()+Math.min(TTL,Math.max(0,b.getLong("expires_ms")-clock.wallMillis()));}
    private boolean expired(Slot s){return clock.monotonicMillis()>=s.deadline;}
    private boolean terminalRoom(){return terminals.size()<MAX_TERMINALS&&clock.monotonicMillis()>=terminalOverflowUntil;}
    private void remember(String account,String id){
        if(terminals.size()<MAX_TERMINALS||terminals.containsKey(key(account,id)))terminals.put(key(account,id),clock.monotonicMillis()+TTL);
        else terminalOverflowUntil=clock.monotonicMillis()+TTL;
    }
    private void purge(){
        long now=clock.monotonicMillis();
        for(Iterator<Slot> it=ready.values().iterator();it.hasNext();)if(it.next().deadline<=now)it.remove();
        for(Iterator<Long> it=terminals.values().iterator();it.hasNext();)if(it.next()<=now)it.remove();
        trim(globalKnocks,now);for(Iterator<ArrayDeque<Long>> it=peerKnocks.values().iterator();it.hasNext();){ArrayDeque<Long> q=it.next();trim(q,now);if(q.isEmpty())it.remove();}
    }
    private boolean allowKnock(String account){
        long now=clock.monotonicMillis();ArrayDeque<Long> q=peerKnocks.get(account);
        if(q==null){if(peerKnocks.size()>=64)return false;q=new ArrayDeque<>();peerKnocks.put(account,q);}
        trim(q,now);trim(globalKnocks,now);if(q.size()>=6||globalKnocks.size()>=24)return false;
        q.addLast(now);globalKnocks.addLast(now);return true;
    }
    private static void trim(ArrayDeque<Long> q,long now){while(!q.isEmpty()&&now-q.peekFirst()>=60_000)q.removeFirst();}
    private String nonce(){byte[] b=new byte[32];random.nextBytes(b);return bytesHex(b);}
    private static String digest(String s){try{return bytesHex(MessageDigest.getInstance("SHA-256").digest(s.getBytes(StandardCharsets.UTF_8)));}catch(Exception e){throw new IllegalStateException(e);}}
    private static String bytesHex(byte[] bytes){char[] h="0123456789abcdef".toCharArray(),out=new char[bytes.length*2];for(int i=0;i<bytes.length;i++){out[i*2]=h[(bytes[i]&255)>>>4];out[i*2+1]=h[bytes[i]&15];}return new String(out);}
    private static boolean hex(String s,int length){return s!=null&&s.length()==length&&s.matches("[0-9a-f]+");}
    private static boolean ice(String s,int min,int max){return s!=null&&s.length()>=min&&s.length()<=max&&s.matches("[a-zA-Z0-9+/]+");}
    private static String key(String account,String id){return account+":"+id;}
}
