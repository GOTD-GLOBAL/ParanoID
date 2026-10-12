#!/usr/bin/env python3
"""REQ-ID-003: execute production refresh/listen and UI routing on a host JVM.

Like test_update_session_worker.py, extract production code verbatim and adapt
only the platform/I/O boundary. Independent worker and UI queues execute the
actual production publish method; Devnet callbacks are held until released.
No sleeps, network, storage writes or Android runtime.
This is not physical Activity/Keystore acceptance.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent


def between(source, start, end):
    return source[source.index(start):source.index(end, source.index(start))]


def main():
    engine = (ROOT / 'src/org/paranoid/text/TextEngine.java').read_text()
    ui = (ROOT / 'src/org/paranoid/text/MainActivity.java').read_text()
    methods = between(engine, '    public void listen(Listener next)', '    private void stopConnection(')
    listener_fields = between(engine, '    private volatile Listener listener;', '    private CallListener')
    directory_method = between(engine, '    public void directoryVisibility(', '    /** Owner proof + card')
    directory_task = between(engine, '    private void directoryTask(', '    /** Prefix search')
    publish = engine[engine.index('    private void publish(String status) {'):engine.rindex('\n}')]
    engine_fields = between(engine, '    private String profileNick=', '    private final CallTones')
    ui_fields = between(ui, '    private boolean active=false,', '    private TextView loginHint;')
    routing = between(ui, '            latest=view;', '            background.setText(')
    create_button = between(ui, '        if(send==null)return;', '        share.setEnabled(')
    open_onboarding = between(ui, '    private void openOnboarding()', '    private void openDevnet()')
    sources = {
        'org/paranoid/devnet/MainActivity.java': '''package org.paranoid.devnet;
import java.util.*;
public class MainActivity {
    public interface Result {void ready(String nick,String state);}
    public static final List<Result> reads=new ArrayList<>();
    public static Runnable scheduled=()->{};
    public static void readPublicProfile(Object context,Result result){scheduled.run();reads.add(result);}
}
''',
        'org/json/JSONArray.java': '''package org.json;
public class JSONArray {
    public int length(){return 0;}
    public org.paranoid.text.NicknameLifecycleTest.JSONObject optJSONObject(int index){return null;}
}
''',
        'org/paranoid/devnet/OnboardingActivity.java': 'package org.paranoid.devnet; public class OnboardingActivity {}',
    }
    harness = '''package org.paranoid.text;
import java.util.*;
import java.io.IOException;
import org.paranoid.devnet.MainActivity;
public class NicknameLifecycleTest {
    static void require(boolean ok,String message){if(!ok)throw new AssertionError(message);}
    static class Queue implements java.util.concurrent.Executor {
        final ArrayDeque<Runnable> tasks=new ArrayDeque<>();
        public void execute(Runnable task){tasks.add(task);}
        int posted;
        public boolean post(Runnable task){posted++;execute(task);return true;}
        void step(){require(!tasks.isEmpty(),"expected queued task");tasks.remove().run();}
        void drain(){while(!tasks.isEmpty())step();}
    }
    public static class JSONObject {
        final Map<String,Object> fields=new HashMap<>();
        JSONObject put(String key,Object value){fields.put(key,value);return this;}
        String optString(String key){return optString(key,"");}
        String optString(String key,String fallback){Object v=fields.get(key);return v instanceof String?(String)v:fallback;}
        boolean optBoolean(String key){return Boolean.TRUE.equals(fields.get(key));}
        long optLong(String key,long fallback){return fallback;}
        org.json.JSONArray optJSONArray(String key){return null;}
    }
    static class SelfServiceClient {
        boolean broken(){return false;}
        JSONObject publicView(){return new JSONObject();}
        String[] updateTrust(){throw new AssertionError("no server trust access expected");}
    }
    static class RealtimeLoop {
        Boolean identityServer(){return false;}
        String directoryName(){return "";}
        JSONObject directory(String operation,String argument){return new JSONObject();}
    }
    static class BackgroundConnectionService {
        static void incoming(Object context){throw new AssertionError("no background notification expected");}
    }
    interface Listener {void changed(JSONObject view,String message);}
    static class Engine {
        final Queue worker=new Queue(),ui=new Queue(),directoryWorker=new Queue();final Object context=new Object();
        interface Directory {void done(JSONObject result,String error);}
        interface OwnerTask<T> {T run()throws Exception;}
        static String directoryError(Throwable error){throw new AssertionError(error);}
        boolean broken,unsupportedSnapshot,connected,backgroundEnabled,callActive,callDraining;
        String lastPublishedStatus="opening";long lastIncoming=-1;
        SelfServiceClient client;RealtimeLoop realtime;
''' + listener_fields + engine_fields + methods + directory_task + directory_method + publish + '''
        void startConnection(){}
        void stopConnection(){}
    }
    static class View {
        static final int GONE=8,VISIBLE=0;
        boolean enabled=true;String text="";
        void setVisibility(int v){}void setAlpha(float v){}
        void setEnabled(boolean v){enabled=v;}boolean isEnabled(){return enabled;}
        void setText(String v){text=v;}
    }
    static class Intent {Intent(Object activity,Class<?> target){}}
    static class Ui implements Listener {
''' + ui_fields + '''
        JSONObject latest=new JSONObject();boolean resumed=true,onboardingOpened;
        String page="dialogs";int opened;
        final List<String> received=new ArrayList<>();
        final View loginHint=new View(),send=new View(),create=new View();
        void startActivity(Intent intent){opened++;}
''' + open_onboarding + '''
        public void changed(JSONObject view,String message){
            received.add(view.optString("nickname_state"));
''' + routing + '''
            buttons();
        }
        void buttons(){
''' + create_button + '''
        }
    }
    static void drain(Engine engine){engine.worker.drain();engine.ui.drain();}
    static void complete(Engine engine,int index,String nick,String state){
        MainActivity.reads.get(index).ready(nick,state);drain(engine);
    }
    static void directoryPublisher(){
        MainActivity.reads.clear();Engine engine=new Engine();Ui view=new Ui();
        engine.realtime=new RealtimeLoop();engine.listen(view);drain(engine);
        int before=engine.ui.posted;int[] completed={0};
        engine.directoryVisibility(true,(result,error)->{require(error==null,"directory callback error");completed[0]++;});
        engine.directoryWorker.drain();
        // Only the directory callback may be queued here. A profile snapshot must
        // wait for the state owner, not read its mutable state on directoryWorker.
        require(engine.ui.posted==before+1,"directory worker published mutable profile outside state owner");
        require(!engine.worker.tasks.isEmpty(),"directory repaint must be queued to state owner");
        complete(engine,0,"alice","verified");
        require(view.hasBlockchainNick&&"verified".equals(view.latest.optString("nickname_state")),"directory repaint erased confirmed nickname");
        require(completed[0]==1,"directory callback must still complete exactly once");
        System.out.println("PASS production directory visibility repaints only on state owner; confirmed nickname retained");
    }
    static void lifecycle(){
        MainActivity.reads.clear();Engine engine=new Engine();
        // The previous Activity saw no nickname; registration then completed on
        // the separate Devnet owner without creating a transport account.
        engine.profileState="none";
        Ui recreated=new Ui();engine.listen(recreated);drain(engine);
        require(recreated.opened==0,"cached none opened onboarding before current read resolved");
        require(engine.profileState.equals("loading"),"refresh must invalidate cached none");
        complete(engine,0,"alice","verified");
        require(recreated.hasBlockchainNick&&!recreated.hasIdentity,"verified nickname must not need transport account");
        require(recreated.opened==0&&recreated.page.equals("identity"),"verified callback must route to profile, not onboarding");
        System.out.println("PASS cached none -> refresh -> no onboarding -> verified, zero transport account");

        MainActivity.scheduled=()->{
            require(engine.profileNick.isEmpty()&&engine.profileState.equals("loading"),"clear nickname before scheduling read");
        };
        int before=engine.ui.posted;
        engine.refreshNicknameProfile();drain(engine);
        require(engine.ui.posted>before,"explicit retry must publish loading without waiting for callback");
        require(!recreated.hasBlockchainNick,"refresh must clear stale displayed nickname");
        engine.refreshNicknameProfile();drain(engine);
        before=engine.ui.posted;
        complete(engine,1,"","none");
        require(engine.ui.posted==before&&engine.profileState.equals("loading"),"stale none callback must be ignored");
        complete(engine,2,"bob","verified");
        complete(engine,1,"alice","verified");
        require(engine.profileNick.equals("bob")&&engine.profileState.equals("verified"),"stale verified must not overwrite current result");
        require(recreated.opened==0,"stale callback triggered onboarding");
        System.out.println("PASS refresh clears/publishes loading before read; stale callbacks ignored");

        engine.refreshNicknameProfile();drain(engine);complete(engine,3,"","unavailable");
        require(recreated.nicknameReadFailed&&!recreated.hasBlockchainNick&&recreated.opened==0,"unavailable is not absence");
        engine.refreshNicknameProfile();drain(engine);complete(engine,4,"","none");
        require(!recreated.nicknameReadFailed&&recreated.opened==1,"current confirmed none must allow onboarding");
        engine.publish("repaint");engine.ui.drain();require(recreated.opened==1,"repaint must not reopen onboarding");
        MainActivity.scheduled=()->{};
        System.out.println("PASS unavailable stays distinct from current none; onboarding opens once");
    }
    static void uiGates(){
        Ui initial=new Ui();initial.buttons();
        require(!initial.create.isEnabled(),"initial loading must disable Begin before first callback");
        initial.openOnboarding();require(initial.opened==0,"initial loading must refuse manual onboarding");
        for(String state:new String[]{"loading","unavailable","none","pending","unregistered","verified"}){
            Ui ui=new Ui();ui.resumed=false;
            ui.changed(new JSONObject().put("nickname_state",state)
                .put("solana_nick",state.equals("verified")?"alice":""),"fixture");
            boolean unresolved=state.equals("loading")||state.equals("unavailable");
            require(ui.create.isEnabled()==(state.equals("none")||state.equals("pending")||state.equals("unregistered")),"Begin action for "+state);
            if(state.equals("loading"))require(ui.create.text.contains("Проверяем"),"loading must show waiting, not Begin");
            ui.openOnboarding();
            require(ui.opened==(unresolved?0:1),"manual onboarding gate for "+state);
        }
        System.out.println("PASS initial/loading/unavailable Begin disabled; manual onboarding blocked; resolved routes retained");
    }
    static void queuedUi(boolean sameActivity){
        MainActivity.reads.clear();Engine engine=new Engine();Ui previous=new Ui();
        engine.listen(previous);drain(engine);
        MainActivity.reads.get(0).ready("","none");engine.worker.drain();
        require(!engine.ui.tasks.isEmpty(),"old none must be waiting on the UI queue");
        engine.unlisten(previous);
        Ui next=sameActivity?previous:new Ui();engine.listen(next);
        // Recreate/resume before delivery, with the new worker refresh still queued.
        engine.ui.drain();
        require(next.opened==0,"Old queued absence reached "+(sameActivity?"reattached":"replacement")+" Activity");
        require(!previous.received.contains("none")&&!next.received.contains("none"),"detached observer received old absence");
        drain(engine);
        require(next.latest.optString("nickname_state").equals("loading")&&!next.create.isEnabled(),"new subscription must await its own read");
        complete(engine,1,"alice","verified");
        require(next.hasBlockchainNick&&next.page.equals("identity")&&next.opened==0,"current verified profile must reach new subscription");
        System.out.println("PASS queued UI none fenced across "+(sameActivity?"same Activity reattach":"Activity replacement"));
    }
    static void queuedWorker(boolean sameActivity,boolean callback){
        MainActivity.reads.clear();Engine engine=new Engine();Ui previous=new Ui();
        previous.resumed=false;engine.listen(previous);drain(engine);
        if(callback){
            // The old read already returned, but its worker callback has not run.
            MainActivity.reads.get(0).ready("","none");
        }else{
            complete(engine,0,"","none");
            // Network/call-log repaint already enqueued ahead of the refresh.
            engine.worker.execute(()->engine.publish("old worker repaint"));
        }
        previous.received.clear();engine.unlisten(previous);
        Ui next=sameActivity?previous:new Ui();next.resumed=true;engine.listen(next);
        engine.worker.step();engine.ui.drain();
        require(next.opened==0&&!next.received.contains("none"),"Pre-refresh queued worker "+(callback?"callback":"publication")+" delivered old absence");
        require(MainActivity.reads.size()==1,"new read must still be queued during the assertion");
        drain(engine);
        require(next.latest.optString("nickname_state").equals("loading")&&!next.create.isEnabled(),"new read must expose loading");
        complete(engine,1,"alice","verified");
        require(next.hasBlockchainNick&&next.opened==0,"current read lost after old worker task");
        System.out.println("PASS queued worker "+(callback?"callback":"repaint")+" fenced across "+(sameActivity?"same Activity reattach":"Activity replacement"));
    }
    static void queuedRefresh(){
        MainActivity.reads.clear();Engine engine=new Engine();Ui current=new Ui();
        engine.listen(current);drain(engine);
        MainActivity.reads.get(0).ready("","none");engine.worker.drain();
        engine.refreshNicknameProfile();
        // A retry must invalidate already-built UI results immediately, not only
        // when its worker task eventually begins.
        engine.ui.drain();
        require(current.opened==0&&!current.received.contains("none"),"Queued old absence reached observer after explicit refresh");
        drain(engine);complete(engine,1,"","unavailable");
        require(current.nicknameReadFailed&&current.opened==0,"unavailable must survive refresh fence without creation");
        System.out.println("PASS explicit refresh fences queued UI before worker begins");
    }
    static void detachedAndSuperseded(){
        MainActivity.reads.clear();Engine engine=new Engine();Ui old=new Ui(),current=new Ui();
        engine.listen(old);drain(engine);
        MainActivity.reads.get(0).ready("","none");engine.worker.drain();
        int delivered=old.received.size();engine.unlisten(old);engine.ui.drain();
        require(old.received.size()==delivered,"detached observer received queued UI snapshot");
        // A result arriving while detached must not update the cached profile.
        complete(engine,0,"stale","verified");
        require(engine.profileNick.isEmpty()&&engine.profileState.equals("none"),"detached callback mutated the profile");
        // Two subscribes before the worker resumes: only the latest may start a read.
        engine.listen(old);engine.listen(current);engine.unlisten(old);drain(engine);
        require(MainActivity.reads.size()==2,"superseded subscription started an obsolete raw read");
        complete(engine,1,"alice","verified");
        require(current.hasBlockchainNick&&old.received.size()==delivered,"late unlisten stole new subscription or delivered to old observer");
        System.out.println("PASS detached callbacks/UI dropped; superseded subscribe and late unlisten preserve current read");
    }
    static void currentStates(){
        for(String state:new String[]{"none","unregistered","pending","unavailable","verified"}){
            MainActivity.reads.clear();Engine engine=new Engine();Ui current=new Ui();
            engine.listen(current);drain(engine);
            require(!current.create.isEnabled()&&current.opened==0,"current loading must wait");
            complete(engine,0,state.equals("verified")?"alice":"",state);
            boolean actionable=state.equals("none")||state.equals("unregistered")||state.equals("pending");
            require(current.latest.optString("nickname_state").equals(state),"current state dropped: "+state);
            require(current.create.isEnabled()==actionable&&current.opened==(actionable?1:0),"current action lost: "+state);
            require(current.nicknameReadFailed==state.equals("unavailable"),"unavailable conflated with absence");
            engine.worker.execute(()->engine.publish("current repaint"));drain(engine);
            require(current.opened==(actionable?1:0),"current repaint reopened onboarding");
        }
        System.out.println("PASS current none/unregistered/pending actionable; unavailable/verified distinct through real queues");
    }
    static void workerScenarios(){
        for(boolean same:new boolean[]{false,true})for(boolean callback:new boolean[]{false,true})queuedWorker(same,callback);
    }
    public static void main(String[] args){directoryPublisher();
        if(args.length==0){lifecycle();uiGates();queuedUi(false);queuedUi(true);workerScenarios();queuedRefresh();detachedAndSuperseded();currentStates();}
        else if(args[0].equals("queued-ui")){queuedUi(false);queuedUi(true);}
        else if(args[0].equals("queued-worker")){workerScenarios();}
        else if(args[0].equals("queued-refresh")){queuedRefresh();}
        else throw new AssertionError("unknown scenario: "+args[0]);
    }
}
'''
    sources['org/paranoid/text/NicknameLifecycleTest.java'] = harness
    with tempfile.TemporaryDirectory(prefix='paranoid-nickname-lifecycle-') as scratch:
        temp = Path(scratch)
        paths = []
        for name, source in sources.items():
            path = temp / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source)
            paths.append(str(path))
        subprocess.run(['javac', '--release', '8', '-Xlint:-options', '-encoding', 'UTF-8',
                        '-d', str(temp), *paths], check=True, timeout=30)
        subprocess.run(['java', '-cp', str(temp), 'org.paranoid.text.NicknameLifecycleTest',
                        *sys.argv[1:]], check=True, timeout=30)


if __name__ == '__main__':
    main()
