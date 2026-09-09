import org.json.JSONObject;
import org.paranoid.text.CallController;
import java.util.ArrayList;
import java.util.List;

/** REQ-CALL-002/003: pure state/consent tests; these do not claim actual media. */
public final class CallControllerSmoke {
    static final String A = repeat('a',64), B = repeat('b',64);
    static final String FP = repeat('1',64), U = "user1234", P = "password123456789012345678";
    static final String SDP = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtcp-mux\r\na=sendrecv\r\na=ice-ufrag:"+U+"\r\na=ice-pwd:"+P+"\r\na=fingerprint:sha-256 "+colon(FP)+"\r\na=setup:actpass\r\na=rtpmap:111 opus/48000/2\r\n";
    static String repeat(char c,int n){StringBuilder s=new StringBuilder();while(n-->0)s.append(c);return s.toString();}
    static String colon(String s){StringBuilder out=new StringBuilder();for(int i=0;i<s.length();i+=2){if(i>0)out.append(':');out.append(s,i,i+2);}return out.toString();}
    static void check(boolean yes,String why){if(!yes)throw new AssertionError(why);}
    static final class Time implements CallController.Clock {
        long wall=1_800_000_000_000L,mono=10_000;
        public long wallMillis(){return wall;}
        public long monotonicMillis(){return mono;}
        void advance(long ms){wall+=ms;mono+=ms;}
    }
    static final class Sent {
        final String account;final JSONObject body;
        Sent(String account,JSONObject body){this.account=account;this.body=new JSONObject(body.toString());}
    }
    static final class Port implements CallController.Port {
        final List<Sent> sent=new ArrayList<>();
        int offers,answers,remoteAnswers,closes;boolean failSave,muted,speaker,holdHeartbeat,deferSignals;
        final List<CallController.Completion> deferred=new ArrayList<>();
        JSONObject view;
        public void send(String account,JSONObject body,CallController.Completion completion){
            if(!failSave)sent.add(new Sent(account,body));
            if(deferSignals)deferred.add(completion);
            else if(!holdHeartbeat||!body.getString("kind").equals("heartbeat"))completion.done(!failSave);
        }
        public void mediaOffer(long generation){offers++;}
        public void mediaAnswer(long generation,String sdp){answers++;}
        public void mediaRemoteAnswer(long generation,String sdp){remoteAnswers++;}
        public void mediaMute(boolean value){muted=value;}
        public void mediaSpeaker(boolean value){speaker=value;}
        public void mediaClose(){closes++;}
        public void changed(JSONObject value){view=new JSONObject(value.toString());}
        Sent take(){check(!sent.isEmpty(),"expected outgoing control");return sent.remove(0);}
    }
    static final class Pair {
        final Time time=new Time();final Port pa=new Port(),pb=new Port();
        final CallController a=new CallController(time,pa),b=new CallController(time,pb);
        Pair(){a.connection(true);b.connection(true);}
        void deliver(CallController recipient,String sender,Sent message){recipient.received(new JSONObject().put("account",sender).put("body",message.body));}
        void ready(){a.start(B,true);deliver(b,A,pa.take());deliver(a,B,pb.take());}
        void ring(){ready();a.localDescription(a.snapshot().getLong("generation"),SDP,FP,U,P);deliver(b,A,pa.take());}
        void connect(){ring();b.answer(true);b.localDescription(b.snapshot().getLong("generation"),SDP.replace("actpass","active"),FP,U,P);deliver(a,B,pb.take());a.mediaState(a.snapshot().getLong("generation"),"connected");b.mediaState(b.snapshot().getLong("generation"),"connected");}
    }
    static void permissionAndFreshness(){
        Pair p=new Pair();p.a.start(B,false);check(p.pa.sent.isEmpty()&&p.pa.offers==0,"denied outgoing permission cannot send or capture");
        p.a.start(B,true);check(p.pa.offers==0,"knock cannot create media");
        p.deliver(p.b,A,p.pa.take());check(p.pb.offers+p.pb.answers==0,"incoming knock cannot create media");
        p.deliver(p.a,B,p.pb.take());check(p.pa.offers==1,"ready permits only explicit caller media");
        p.a.localDescription(p.a.snapshot().getLong("generation"),SDP,FP,U,P);Sent offer=p.pa.take();
        Port restartedPort=new Port();CallController restarted=new CallController(p.time,restartedPort);restarted.connection(true);
        p.deliver(restarted,A,offer);check(!"incoming".equals(restarted.snapshot().getString("state")),"old offer cannot ring after restart");
        p.deliver(p.b,A,offer);check("incoming".equals(p.b.snapshot().getString("state")),"matching fresh offer rings");
        check(p.pb.answers==0,"incoming ring never captures");p.b.answer(false);check(p.pb.answers==0&&!p.b.active(),"denied Answer closes without capture");
    }
    static void lifecycleAndCommit(){
        Pair p=new Pair();p.connect();check(p.pa.remoteAnswers==1,"caller applies authenticated answer");
        check("connected".equals(p.a.snapshot().getString("state")),"actual media callback drives connected");
        p.a.mute(true);p.a.speaker(true);check(p.pa.muted&&p.pa.speaker,"route and mute reach actual media port");
        long oldGeneration=p.a.snapshot().getLong("generation");p.a.hangup();check(!p.a.active()&&p.pa.closes>0,"local end cleans media");
        int before=p.pa.sent.size();p.a.localDescription(oldGeneration,SDP,FP,U,P);p.a.mediaState(oldGeneration,"connected");
        check(!p.a.active()&&p.pa.sent.size()==before,"stale callbacks cannot recreate call or signaling");
        p.deliver(p.b,A,p.pa.take());check(!p.b.active()&&p.pb.closes>0,"remote end cleans media");
        Pair failed=new Pair();failed.pa.failSave=true;failed.a.start(B,true);check(!failed.a.active()&&failed.pa.offers==0,"failed durable enqueue grants no media authority");
    }
    static void wrongContextsAndReplay(){
        Pair p=new Pair();p.ready();p.a.localDescription(p.a.snapshot().getLong("generation"),SDP,FP,U,P);Sent offer=p.pa.take();
        Sent wrong=new Sent(B,offer.body);wrong.body.put("callee_nonce",repeat('f',64));p.deliver(p.b,A,wrong);
        check(!"incoming".equals(p.b.snapshot().getString("state")),"wrong readiness nonce cannot ring");
        p.deliver(p.b,A,offer);check("incoming".equals(p.b.snapshot().getString("state")),"invalid event did not consume legitimate slot");
        p.deliver(p.b,A,offer);check(p.pb.answers==0&&"incoming".equals(p.b.snapshot().getString("state")),"duplicate offer cannot capture or reset call");
        p.b.reject();check(!p.b.active(),"explicit rejection terminal");p.deliver(p.b,A,offer);check(!p.b.active(),"late offer cannot resurrect rejected call");
        Pair expired=new Pair();expired.ready();expired.time.advance(45_001);expired.b.tick();expired.a.localDescription(expired.a.snapshot().getLong("generation"),SDP,FP,U,P);
        if(!expired.pa.sent.isEmpty())expired.deliver(expired.b,A,expired.pa.take());check(!"incoming".equals(expired.b.snapshot().getString("state")),"expired readiness cannot ring");
    }
    static void heartbeatAndAuthority(){
        Pair p=new Pair();p.connect();p.time.advance(10_001);p.a.tick();p.b.tick();
        check("heartbeat".equals(p.pa.take().body.getString("kind")),"active caller sends authenticated heartbeat");
        check("heartbeat".equals(p.pb.take().body.getString("kind")),"active callee sends authenticated heartbeat");
        p.time.advance(20_001);p.a.tick();p.b.tick();check(!p.a.active()&&!p.b.active(),"peer silence ends both media paths");
        Pair revoked=new Pair();revoked.connect();revoked.a.authorizationLost();check(!revoked.a.active()&&revoked.pa.closes>0,"known auth loss stops immediately");
        Pair blocked=new Pair();blocked.connect();blocked.b.block(A);check(!blocked.b.active()&&blocked.pb.closes>0,"block stops active peer");
        Pair pending=new Pair();pending.connect();pending.pa.holdHeartbeat=true;pending.time.advance(10_001);pending.a.tick();pending.time.advance(10_001);pending.a.tick();
        check(pending.pa.sent.size()==1,"only one heartbeat may await actual server acceptance");
        Pair offline=new Pair();offline.a.connection(false);offline.a.start(B,true);check(offline.pa.sent.isEmpty()&&offline.pa.offers==0,"offline call does not enter durable outbox");
    }
    static void crossingAndClock(){
        Pair p=new Pair();p.a.start(B,true);p.b.start(A,true);Sent ak=p.pa.take(),bk=p.pb.take();p.deliver(p.b,A,ak);p.deliver(p.a,B,bk);
        while(!p.pa.sent.isEmpty())p.deliver(p.b,A,p.pa.take());while(!p.pb.sent.isEmpty())p.deliver(p.a,B,p.pb.take());
        check(!p.a.active()&&!p.b.active()&&p.pa.offers+p.pb.offers==0,"crossing attempts end busy without implicit answer");
        Pair jump=new Pair();jump.ready();jump.time.wall-=60_000;jump.b.tick();jump.a.tick();check(!jump.a.active(),"wall-clock rollback cannot extend negotiation");
    }
    static void answerBindingAndTerminal(){
        Pair p=new Pair();p.ring();p.b.answer(true);p.b.localDescription(p.b.snapshot().getLong("generation"),SDP.replace("actpass","active"),FP,U,P);
        Sent answer=p.pb.take();Sent wrong=new Sent(A,answer.body);wrong.body.put("offer_digest",repeat('f',64));p.deliver(p.a,B,wrong);
        check(p.pa.remoteAnswers==0,"wrong offer digest never enters media engine");
        wrong=new Sent(A,answer.body);wrong.body.put("caller_nonce",repeat('f',64));p.deliver(p.a,B,wrong);check(p.pa.remoteAnswers==0,"wrong caller nonce never enters media engine");
        p.deliver(p.a,B,answer);p.deliver(p.a,B,answer);check(p.pa.remoteAnswers==1,"answer applies once");
        Pair cancel=new Pair();cancel.a.start(B,true);Sent knock=cancel.pa.take();cancel.a.hangup();cancel.deliver(cancel.b,A,knock);Sent ready=cancel.pb.take();cancel.deliver(cancel.a,B,ready);
        check(cancel.pa.offers==0&&!cancel.a.active(),"late ready cannot reopen caller intent");
        Pair end=new Pair();end.ready();end.a.hangup();end.deliver(end.b,A,end.pa.take());
        check(end.pb.answers==0&&!end.b.active(),"post-ready pre-offer end closes readiness without capture");
    }
    static void engineLimitsAndCallbacks(){
        Pair p=new Pair();p.connect();p.a.mediaState(p.a.snapshot().getLong("generation"),"disconnected");check(p.a.snapshot().getBoolean("reconnecting"),"ICE loss is visible before its failure deadline");p.time.advance(9_999);p.a.tick();check(p.a.active(),"brief ICE loss gets bounded recovery");
        p.a.mediaState(p.a.snapshot().getLong("generation"),"connected");p.time.advance(1);p.a.tick();check(p.a.active()&&!p.a.snapshot().getBoolean("reconnecting"),"ICE reconnection cancels disconnect deadline and presentation");
        p.a.mediaState(p.a.snapshot().getLong("generation"),"disconnected");p.time.advance(10_001);p.a.tick();check(!p.a.active(),"ICE disconnection deadline cleans media");
        Pair large=new Pair();large.ready();large.a.localDescription(large.a.snapshot().getLong("generation"),repeat('x',6145),FP,U,P);check(!large.a.active()&&large.pa.closes>0,"oversized local SDP cleans capture before offer");
        Pair failed=new Pair();failed.ready();failed.pa.failSave=true;failed.a.localDescription(failed.a.snapshot().getLong("generation"),SDP,FP,U,P);check(!failed.a.active()&&failed.pa.closes>0,"offer enqueue failure cleans already-created caller media");
        Pair limited=new Pair();limited.connect();for(int n=0;n<90&&limited.a.active();n++){
            limited.time.advance(10_000);limited.a.tick();limited.b.tick();
            while(!limited.pa.sent.isEmpty())limited.deliver(limited.b,A,limited.pa.take());while(!limited.pb.sent.isEmpty())limited.deliver(limited.a,B,limited.pb.take());
        }
        check(!limited.a.active()&&!limited.b.active(),"15-minute limit holds with healthy heartbeats");
    }
    static void delayedCompletionIsolation(){
        Pair p=new Pair();p.pa.deferSignals=true;p.a.start(B,true);CallController.Completion oldKnock=p.pa.deferred.get(0);long old=p.a.snapshot().getLong("generation");
        p.a.hangup();p.a.start(B,true);long current=p.a.snapshot().getLong("generation");check(current!=old&&p.a.active(),"new intent has a fresh generation");
        oldKnock.done(false);check(p.a.active()&&p.a.snapshot().getLong("generation")==current,"late old rejection cannot terminate a new call");
        oldKnock.done(true);p.a.mediaState(old,"failed");p.a.localDescription(old,SDP,FP,U,P);check(p.a.active()&&p.pa.offers==0,"old acceptance and media callbacks cannot mutate new intent");
        p.pa.deferred.get(p.pa.deferred.size()-1).done(false);check(!p.a.active(),"current asynchronous enqueue failure still terminates");
    }
    static void cancelBeforeReadyDelivery(){
        Pair p=new Pair();p.a.start(B,true);p.deliver(p.b,A,p.pa.take());
        check(p.pb.sent.size()==1,"receiver readiness exists while ready response is delayed");
        p.a.hangup();Sent cancel=p.pa.take();check(cancel.body.getString("callee_nonce").isEmpty(),"caller cannot know undelivered ready nonce");p.deliver(p.b,A,cancel);
        p.a.start(B,true);p.deliver(p.b,A,p.pa.take());check(p.pb.sent.size()==2,"pre-ready cancel releases peer readiness for immediate fresh knock");
        p.pb.take();p.deliver(p.a,B,p.pb.take());check(p.pa.offers==1,"fresh ready after cancellation permits only fresh caller intent");
        Pair active=new Pair();active.ring();active.a.hangup();Sent correct=active.pa.take(),empty=new Sent(B,correct.body);
        empty.body.put("callee_nonce","").put("offer_digest","");active.deliver(active.b,A,empty);
        check(active.b.active()&&"incoming".equals(active.b.snapshot().getString("state")),"empty pre-ready end cannot terminate active ringing context");
        active.deliver(active.b,A,correct);check(!active.b.active(),"exact ringing end still terminates");
    }
    public static void main(String[] args){permissionAndFreshness();lifecycleAndCommit();wrongContextsAndReplay();heartbeatAndAuthority();crossingAndClock();answerBindingAndTerminal();engineLimitsAndCallbacks();delayedCompletionIsolation();cancelBeforeReadyDelivery();System.out.println("CallControllerSmoke PASS: consent, freshness, replay, lifecycle, persistence failure, heartbeat, crossing, clock, answer binding, media bounds, delayed callbacks, pre-ready cancel");}
}
