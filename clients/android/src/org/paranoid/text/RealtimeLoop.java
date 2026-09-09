package org.paranoid.text;

import org.json.JSONArray;
import org.json.JSONObject;
import java.io.IOException;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

/** Two network lanes; all native state and commits stay on the supplied owner. */
public final class RealtimeLoop implements AutoCloseable {
    public interface Listener {
        void changed(boolean connected,String status);
        default void authorizationLost(){}
    }
    private final ExecutorService owner;
    private final SelfServiceClient client;
    private final Listener listener;
    private final ExecutorService network=Executors.newFixedThreadPool(2,r->{Thread t=new Thread(r,"paranoid-network");t.setDaemon(true);return t;});
    private final Object lifecycle=new Object(),sessionGate=new Object(),proofGate=new Object(),wakeGate=new Object();
    private final Semaphore outbound=new Semaphore(0);
    private final AtomicBoolean cancelling=new AtomicBoolean();
    private volatile boolean enabled,closed;
    private volatile long generation;
    private volatile RealtimeTransport transport;
    private volatile Session session;
    private volatile boolean discoveryNeeded=true,realtime;
    private long discoveryAt,lastProof;
    private volatile long legacyUntil;
    private static final class Session {
        final JSONObject context;final long received=System.nanoTime();
        Session(JSONObject context){this.context=context;}
        boolean renew(){return System.nanoTime()-received>=240_000_000_000L;}
    }
    private static final class Idle extends Exception {}
    public RealtimeLoop(ExecutorService owner,SelfServiceClient client,Listener listener) {
        this.owner=owner;this.client=client;this.listener=listener;
        network.execute(this::sendLoop);network.execute(this::receiveLoop);
    }
    public void start(){synchronized(lifecycle){if(closed)return;if(!enabled){enabled=true;generation++;}lifecycle.notifyAll();}kick();}
    public void kick(){synchronized(wakeGate){if(outbound.availablePermits()==0)outbound.release();}}
    public void stop(){
        synchronized(lifecycle){enabled=false;generation++;lifecycle.notifyAll();}kick();
        RealtimeTransport current=transport;
        if(current!=null&&cancelling.compareAndSet(false,true)) {
            Thread cancel=new Thread(()->{try{current.cancelActive();}finally{cancelling.set(false);}},"paranoid-cancel");cancel.setDaemon(true);cancel.start();
        }
    }
    private long awaitEnabled()throws InterruptedException {
        synchronized(lifecycle){while(!enabled&&!closed)lifecycle.wait();if(closed)throw new InterruptedException();return generation;}
    }
    private boolean current(long run){return enabled&&!closed&&generation==run;}
    private void guard(long run)throws InterruptedException {if(!current(run)||Thread.currentThread().isInterrupted())throw new InterruptedException();}
    private <T> T state(long run,Callable<T> task)throws Exception {
        guard(run);
        Future<T> result=owner.submit(()->{
            guard(run);
            if(client.broken())throw new IOException("local state frozen");
            try{return task.call();}
            catch(Exception failure){if(client.broken()){enabled=false;listener.authorizationLost();listener.changed(false,"Ошибка хранения. Данные сохранены; подключение остановлено.");}throw failure;}
        });
        try{return result.get();}
        catch(ExecutionException failure){Throwable cause=failure.getCause();if(cause instanceof Exception)throw (Exception)cause;throw new IOException("state operation failed");}
    }
    private void publish(long run,boolean connected,String message) {
        if(!current(run))return;
        owner.execute(()->{if(current(run))listener.changed(connected,message);});
    }
    private void authorityFailure(long run,Exception failure){
        if(failure instanceof SyncCycle.Rejected&&((SyncCycle.Rejected)failure).status==401)
            owner.execute(()->{if(current(run))listener.authorizationLost();});
    }
    private void pause(long run,long millis)throws InterruptedException {
        long end=System.nanoTime()+TimeUnit.MILLISECONDS.toNanos(millis);
        synchronized(lifecycle){while(current(run)){long left=end-System.nanoTime();if(left<=0)return;TimeUnit.NANOSECONDS.timedWait(lifecycle,left);}}
        guard(run);
    }
    private JSONObject proof(long run,String purpose,String method,String path,String body)throws Exception {
        synchronized(proofGate) {
            guard(run);long wait=600_000_000L-(System.nanoTime()-lastProof);
            if(wait>0)pause(run,TimeUnit.NANOSECONDS.toMillis(wait)+1);
            JSONObject intent=state(run,()->client.challengeIntent(purpose,method,path,body));lastProof=System.nanoTime();
            JSONObject challenge=transport.call("POST",purpose.equals("register")?"/v2/registration/challenge":"/v2/auth/challenge",intent.toString(),null);
            String authorization=state(run,()->client.requestProof(challenge,method,path,body));
            guard(run);return transport.call(method,path,body,authorization);
        }
    }
    private Session connection(long run)throws Exception {
        synchronized(sessionGate) {
            guard(run);
            if(!state(run,client::hasIdentity))throw new Idle();
            if(transport==null){String[] trust=state(run,client::updateTrust);transport=new RealtimeTransport(trust[0],trust[1]);}
            if(!state(run,client::registered)) {
                JSONObject status=proof(run,"register","POST","/v2/registration/commit","{}");
                state(run,()->{client.registrationResult(status);listener.changed(true,"Подключено");return null;});
            }
            if(discoveryNeeded||System.nanoTime()-discoveryAt>60_000_000_000L) {
                JSONObject health=transport.call("GET","/health","",null);
                if(!health.optString("protocol").equals("paranoid-self-service-v2")||!health.optString("status").equals("ok"))throw new IOException("server protocol mismatch");
                realtime=health.optString("realtime").equals("signed-long-poll-v1");discoveryNeeded=false;discoveryAt=System.nanoTime();
                if(!realtime)session=null;
            }
            if(!realtime||System.nanoTime()<legacyUntil)return null;
            Session existing=session;if(existing!=null&&!existing.renew())return existing;
            try {
                JSONObject context=proof(run,"session","POST","/v2/session","{}");
                // Native strict parser and saved identity/trust validation before use.
                state(run,()->client.sessionRequest(context,"messages",null));
                Session next=new Session(context);session=next;return next;
            } catch(SyncCycle.Rejected error) {
                if(error.status==401||error.status==404){session=null;discoveryNeeded=true;throw error;}
                if(error.status==429){legacyUntil=System.nanoTime()+5_000_000_000L;return null;}
                throw error;
            }
        }
    }
    private JSONObject sessionCall(long run,Session context,String operation,String id)throws Exception {
        for(int attempt=0;;attempt++) {
            JSONObject request=state(run,()->client.sessionRequest(context.context,operation,id));
            guard(run);
            try{return transport.call(request.getString("method"),request.getString("path"),request.getString("body"),request.getString("authorization"));}
            catch(SyncCycle.Rejected error) {
                // A pooled connection can lose the response after nonce consumption.
                // One exact immutable retry with a newly signed nonce is safe.
                if(error.status==401&&attempt==0)continue;
                if(error.status==401||error.status==404||error.code.equals("session_exhausted")) {
                    if(session==context)session=null;
                    if(error.status==404||error.status==401)discoveryNeeded=true;
                }
                throw error;
            }
        }
    }
    private void sendLoop() {
        int failures=0;
        while(!closed) {
            long run=0;
            try {
                run=awaitEnabled();if(!outbound.tryAcquire(1,TimeUnit.SECONDS))continue;final long selected=run;
                Session context=connection(run);
                JSONArray pending=state(run,client::pending);
                Exception deferred=null;
                for(int n=0;n<pending.length();n++) {
                    guard(run);JSONObject envelope=pending.getJSONObject(n);JSONObject accepted;
                    try {
                        accepted=context==null?proof(run,"message","POST","/v2/messages",envelope.toString()):sessionCall(run,context,"send",envelope.getString("id"));
                        state(selected,()->{client.accepted(envelope,accepted);listener.changed(true,"Подключено");return null;});
                    } catch(SyncCycle.Rejected error){if(error.status!=409&&error.status!=507)throw error;deferred=error;}
                }
                if(deferred!=null)throw deferred;
                failures=0;
            } catch(Idle idle){/* Local ID creation is user-controlled. */}
            catch(InterruptedException interrupted){if(closed)return;}
            catch(Exception failure) {
                if(!current(run))continue;
                authorityFailure(run,failure);
                publish(run,false,errorMessage(failure));
                try{pause(run,backoff(++failures));kick();}catch(InterruptedException ignored){}
            }
        }
    }
    private void receiveLoop() {
        int failures=0;
        long observedRun=-1;
        while(!closed) {
            long run=0;
            try {
                run=awaitEnabled();final long selected=run;Session context=connection(run);
                long after=state(run,client::receiveCursor);JSONObject page;boolean polling=context==null;
                if(context==null)page=proof(run,"message","GET","/v2/messages?after="+after+"&limit=20","");
                else {
                    // A resumed empty inbox must confirm actual authenticated
                    // readiness before waiting through a full long-poll timeout.
                    try{page=sessionCall(run,context,observedRun==run?"events":"messages",null);}
                    catch(SyncCycle.Rejected busy){if(busy.status!=429||!busy.code.equals("waiter_busy"))throw busy;page=sessionCall(run,context,"messages",null);polling=true;}
                }
                JSONArray messages=page.getJSONArray("messages");
                if(messages.length()>20)throw new IOException("page limit");
                state(selected,()->{
                    if(client.receiveCursor()!=after)throw new IOException("stale receive page");
                    for(int n=0;n<messages.length();n++) {
                        client.received(messages.getJSONObject(n));
                        // Persist succeeded. UI notification is issued before a receipt
                        // can enter the send lane, even if that network is stalled.
                        listener.changed(true,"Подключено");
                    }
                    if(messages.length()==0)listener.changed(true,"Подключено");
                    return null;
                });
                observedRun=run;
                kick();failures=0;
                if(polling&&messages.length()<20)pause(run,3000);
            } catch(Idle idle){try{pause(run,500);}catch(InterruptedException ignored){}}
            catch(InterruptedException interrupted){if(closed)return;}
            catch(Exception failure) {
                if(!current(run))continue;
                authorityFailure(run,failure);
                publish(run,false,errorMessage(failure));
                try{pause(run,backoff(++failures));}catch(InterruptedException ignored){}
            }
        }
    }
    private static long backoff(int failures){return Math.min(30_000L,500L*(1L<<Math.min(failures,5)))+ThreadLocalRandom.current().nextInt(250);}
    private static String errorMessage(Exception failure) {
        if(failure instanceof SyncCycle.Rejected) {
            int code=((SyncCycle.Rejected)failure).status;
            if(code==507)return "Хранилище сервера заполнено. Сообщения сохранены в очереди.";
            if(code==401||code==409)return "Не удалось подтвердить подключение. ID и сообщения сохранены.";
            if(code==429)return "Сервер занят. Повторяем подключение.";
        }
        return "Нет подключения. Сообщения сохранены в очереди.";
    }
    @Override public void close(){closed=true;stop();network.shutdownNow();RealtimeTransport current=transport;if(current!=null)current.close();}
}
