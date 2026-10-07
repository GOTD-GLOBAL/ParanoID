#!/usr/bin/env python3
"""RFC-0028 / REQ-ID-003,006,007: production shareLink + TextEngine on a host JVM.

Extract production methods verbatim (including real onOwner/directoryTask/error
mapping and pause/destroy hooks). Deterministic independent owner/network/UI
queues and adapters replace Android and network only. No network, persistence,
JNI or physical Activity acceptance is claimed. The real SDK compile is separate.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent


def between(source, start, end):
    return source[source.index(start):source.index(end, source.index(start))]


def main():
    source = (ROOT / 'src/org/paranoid/text/MainActivity.java').read_text()
    engine = (ROOT / 'src/org/paranoid/text/TextEngine.java').read_text()
    share = between(source, '    private boolean sharingLink;', '    private void pasteContact(){')
    methods = between(engine, '    private interface OwnerTask', '    /** Prefix search')
    errors = between(engine, '    private static String directoryError(', '    private String userError(')
    lifecycle = between(source, '    @Override public void onPause()', '    private void attachRenderers()')
    change = between(source, '    @Override public void changed(', '            boolean hadProfile=')
    change = change[change.index('        try{') + len('        try{'):]
    harness = r'''import org.json.JSONObject;
import java.util.*;
import java.util.concurrent.*;
import java.io.IOException;
public class ShareLinkTest {
    static void require(boolean ok,String message){if(!ok)throw new AssertionError(message);}
    static String lane="ui";
    static void onLane(String expected){require(lane.equals(expected),"expected "+expected+", on "+lane);}
    static final String PIN="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    static final String SERVER=PIN.substring(0,16),CARD="own-card-fingerprint";
    static class Queue extends AbstractExecutorService {
        final String name;final ArrayDeque<Runnable> tasks=new ArrayDeque<>();
        Queue(String name){this.name=name;}
        public void execute(Runnable task){tasks.add(task);}
        void post(Runnable task){execute(task);}
        void step(){require(!tasks.isEmpty(),"queue empty: "+name);String prev=lane;lane=name;try{tasks.remove().run();}finally{lane=prev;}}
        void drain(){while(!tasks.isEmpty())step();}
        protected <T> RunnableFuture<T> newTaskFor(Callable<T> task){
            return new FutureTask<T>(task){
                public T get(long timeout,TimeUnit unit)throws InterruptedException,ExecutionException,TimeoutException {
                    onLane("directory");while(!isDone())step();return super.get(timeout,unit);
                }
            };
        }
        public void shutdown(){}public List<Runnable> shutdownNow(){return Collections.emptyList();}
        public boolean isShutdown(){return false;}public boolean isTerminated(){return false;}
        public boolean awaitTermination(long t,TimeUnit u){return true;}
    }
    static class SelfServiceClient {
        String account="account-a",card=CARD;
        String[] trust={"https://known.test:38444",PIN};boolean active=true;
        JSONObject publicView(){onLane("owner");return new JSONObject().put("active",active).put("account",account);}
        String[] updateTrust(){onLane("owner");return trust;}
        String cardFingerprint(){onLane("owner");return card;}
    }
    static class RealtimeLoop {
        int requests;Boolean supported=true;Exception failure;
        JSONObject response=new JSONObject().put("published",true).put("name","advix").put("card",PIN);
        Runnable during=()->{};
        Boolean identityServer(){onLane("owner");return supported;}
        JSONObject directory(String operation,String argument)throws Exception {
            onLane("directory");require(operation.equals("directory_card")&&argument==null,"only existing signed card route allowed");
            requests++;during.run();if(failure!=null)throw failure;return response;
        }
    }
    static class Engine {
        final Queue worker=new Queue("owner"),directoryWorker=new Queue("directory"),ui=new Queue("ui");
        SelfServiceClient client=new SelfServiceClient();RealtimeLoop realtime=new RealtimeLoop();
        boolean broken,connected=true;
        interface Directory {void done(JSONObject result,String error);}
''' + methods + errors + r'''
        void unlisten(Object listener){}void unlistenCalls(Object listener){}
        Calls calls(){return new Calls();}
    }
    static class Calls {boolean active(){return false;}JSONObject snapshot(){return new JSONObject();}void video(boolean b){}}
    static class Toast {
        static final int LENGTH_LONG=1;static final List<String> messages=new ArrayList<>();
        static Toast makeText(Object context,String message,int length){onLane("ui");messages.add(message);return new Toast();}
        void show(){}
    }
    static class Button {
        boolean enabled=true;String text="";
        void setEnabled(boolean value){onLane("ui");enabled=value;}void setText(String value){onLane("ui");text=value;}
    }
    static class Intent {
        static final String ACTION_SEND="send",EXTRA_TEXT="text";
        String text,type;
        Intent(String action){require(action.equals(ACTION_SEND),"share action");}
        void setType(String type){this.type=type;}
        void putExtra(String key,String value){require(key.equals(EXTRA_TEXT),"share payload");text=value;}
        static Intent createChooser(Intent intent,String title){return intent;}
    }
    static class Activity {public void onPause(){}public void onDestroy(){}}
    static class Handler {void removeCallbacks(Object runnable){}}
    static class Dialog {void dismiss(){}}
    static class Ui extends Activity {
        final Engine engine=new Engine();
        JSONObject latest=new JSONObject().put("identity",true).put("active",true).put("connected",true).put("directory",true)
            .put("directory_name","").put("server_id",SERVER).put("solana_nick","advix")
            .put("account","account-a").put("contact_fingerprint",CARD);
        final Button shareLink=new Button();List<Intent> sent=new ArrayList<>();
        boolean resumed=true,finishing,destroyed,waitingForMicrophone,waitingForCamera,videoPausedByBackground;
        final Handler handler=new Handler();Object poll,callListener;Dialog callDialog;
        boolean isFinishing(){return finishing;}boolean isDestroyed(){return destroyed;}
        void cancelCallIntent(){}
        void startActivity(Intent intent){onLane("ui");require(intent.type.equals("text/plain"),"share MIME");sent.add(intent);}
        void changed(JSONObject view){
''' + change + r'''
            latest=view;
        }
''' + share + lifecycle + r'''
    }
    static Ui fresh(){Toast.messages.clear();return new Ui();}
    static void finish(Ui ui){ui.engine.directoryWorker.drain();ui.engine.ui.drain();}
    static void cleared(Ui ui){require(!ui.sharingLink&&ui.shareLink.enabled&&ui.shareLink.text.equals("Поделиться моей ссылкой"),"pending share UI not reset");}
    static void screenshot(){
        Ui ui=fresh();ui.shareLink();
        require(Toast.messages.isEmpty(),"connected + active + directory-ready with empty directory_name must not say reconnect: "+Toast.messages);
        require(ui.sent.isEmpty()&&ui.engine.realtime.requests==0,"sharing must be asynchronous");
        require(ui.sharingLink&&!ui.shareLink.enabled,"pending share button disabled");
        for(int i=0;i<20;i++)ui.shareLink();
        require(ui.engine.directoryWorker.tasks.size()==1,"duplicate taps flood network queue");
        finish(ui);
        require(ui.engine.realtime.requests==1&&ui.sent.size()==1,"one request and one share");
        require(ui.sent.get(0).text.equals("Напишите мне в ParanoID: https://paranoid.global/c/"+SERVER+"/advix"),"confirmed server link");
        cleared(ui);
        ui=fresh();ui.latest.put("directory_name","old_name").put("solana_nick","unrelated_nick");
        ui.engine.realtime.response.put("name","confirmed_name");ui.shareLink();finish(ui);
        require(ui.sent.get(0).text.endsWith("/confirmed_name"),"cache/global nickname used as server membership");
        System.out.println("PASS screenshot path + async production owner/network/UI lanes + duplicate taps + no cache/global nick authority");
    }
    static void error(Ui ui,String expected){
        ui.shareLink();finish(ui);require(ui.sent.isEmpty(),"error must not share");cleared(ui);
        require(Toast.messages.size()==1&&Toast.messages.get(0).contains(expected),"specific error expected "+expected+": "+Toast.messages);
        require(!Toast.messages.get(0).contains("Ссылка появится после подключения"),"old reconnect misdiagnosis");
    }
    static void errors(){
        Ui ui=fresh();ui.engine.connected=false;error(ui,"Нет подключения");require(ui.engine.realtime.requests==0,"offline preflight");
        ui=fresh();ui.engine.realtime.failure=new IOException("offline");error(ui,"Нет подключения");
        ui=fresh();ui.engine.realtime.supported=false;error(ui,"не поддерживает");require(ui.engine.realtime.requests==0,"unsupported preflight");
        ui=fresh();ui.engine.realtime.failure=new SyncCycle.Rejected(404,"directory_unavailable");error(ui,"не поддерживает");
        ui=fresh();ui.engine.realtime.failure=new SyncCycle.Rejected(401,"unauthorized");error(ui,"не подтвердил вход");
        ui=fresh();ui.engine.client.active=false;error(ui,"Сначала войдите");require(ui.engine.realtime.requests==0,"global nickname is not membership");
        ui=fresh();ui.engine.client.card="";error(ui,"Карточка контакта пока недоступна");require(ui.engine.realtime.requests==0,"no card must not publish");
        ui=fresh();ui.engine.realtime.failure=new IOException("timeout");error(ui,"timeout");
        ui=fresh();ui.engine.realtime.failure=new SyncCycle.Rejected(429,"directory_rate");error(ui,"Слишком много запросов");
        System.out.println("PASS offline/unsupported/unauthorized/inactive/missing-card/network/rate errors remain specific");
    }
    static void malformed(){
        for(Object value:new Object[]{false,"true",1,JSONObject.NULL}){
            Ui ui=fresh();ui.engine.realtime.response.put("published",value);error(ui,"некорректные данные карточки");
        }
        for(Object name:new Object[]{"","ab","Advix","a/b","a b","%61dvix","аdvix","a2345678901234567890123456",123,JSONObject.NULL}){
            Ui ui=fresh();ui.engine.realtime.response.put("name",name);error(ui,"некорректные данные карточки");
        }
        for(Object card:new Object[]{"","A"+PIN.substring(1),123,JSONObject.NULL}){
            Ui ui=fresh();ui.engine.realtime.response.put("card",card);error(ui,"некорректные данные карточки");
        }
        Ui ui=fresh();ui.engine.realtime.response=null;error(ui,"некорректные данные карточки");
        for(String name:new String[]{"abc","a_b",new String(new char[24]).replace('\0','a')}){
            ui=fresh();ui.engine.realtime.response.put("name",name);ui.shareLink();finish(ui);require(ui.sent.size()==1&&ui.sent.get(0).text.endsWith("/"+name),"canonical boundary "+name);
        }
        System.out.println("PASS strict published Boolean, canonical name boundaries and malformed card responses");
    }
    static void trust(){
        for(String pin:new String[]{"",PIN.substring(0,63),"A"+PIN.substring(1),PIN+"0","g"+PIN.substring(1)}){
            Ui ui=fresh();ui.engine.client.trust[1]=pin;error(ui,"Не удалось подтвердить текущий сервер");require(ui.engine.realtime.requests==0,"invalid pin reached network");
        }
        for(String[] trust:new String[][]{null,{}, {"realm"},{"",PIN},{null,PIN},{"realm",null}}){
            Ui ui=fresh();ui.engine.client.trust=trust;error(ui,"Не удалось подтвердить текущий сервер");
        }
        for(String server:new String[]{"","fedcba9876543210",SERVER+"a",SERVER.toUpperCase()}){
            Ui ui=fresh();ui.latest.put("server_id",server);error(ui,"Не удалось подтвердить текущий сервер");require(ui.engine.realtime.requests==0,"untrusted server id reached network");
        }
        Ui ui=fresh();ui.engine.realtime.response.put("server_id","fedcba9876543210");ui.shareLink();finish(ui);
        require(ui.sent.get(0).text.contains("/"+SERVER+"/"),"server reply cannot select trust");
        System.out.println("PASS existing full trusted pin + derived server id validation; response cannot choose server");
    }
    static void ownerContext(){
        for(int mode=0;mode<7;mode++){
            final Ui ui=fresh();final int variant=mode;
            ui.engine.realtime.during=()->ui.engine.worker.execute(()->{
                onLane("owner");
                switch(variant){
                    case 0:ui.engine.client.account="account-b";break;
                    case 1:ui.engine.client.card="card-b";break;
                    case 2:ui.engine.client.trust[0]="https://other.test";break;
                    case 3:ui.engine.client.trust[1]=PIN.substring(0,63)+"0";break;
                    case 4:ui.engine.realtime=new RealtimeLoop();break;
                    case 5:ui.engine.client=new SelfServiceClient();break;
                    case 6:ui.engine.client.active=false;break;
                }
            });
            ui.shareLink();finish(ui);cleared(ui);
            require(ui.sent.isEmpty()&&Toast.messages.isEmpty(),"owner context change must ignore success callback, not toast about old context: "+mode+" "+Toast.messages);
        }
        final Ui queued=fresh();queued.engine.worker.execute(()->queued.engine.client.account="account-b");queued.shareLink();finish(queued);cleared(queued);
        require(queued.engine.realtime.requests==0&&queued.sent.isEmpty()&&Toast.messages.isEmpty(),"queued old account reached network/UI");
        Ui ui=fresh();ui.latest.put("contact_fingerprint","old-card");ui.shareLink();finish(ui);cleared(ui);
        require(ui.engine.realtime.requests==0&&ui.sent.isEmpty()&&Toast.messages.isEmpty(),"queued old card reached network/UI");
        final Ui failed=fresh();failed.engine.realtime.failure=new SyncCycle.Rejected(401,"unauthorized");
        failed.engine.realtime.during=()->failed.engine.worker.execute(()->failed.engine.client.account="account-b");
        failed.shareLink();finish(failed);cleared(failed);
        require(failed.sent.isEmpty()&&Toast.messages.isEmpty(),"must recheck owner context and ignore error callback after failed network too");
        System.out.println("PASS owner rechecks account/card/full realm+pin/client/loop before and after network");
    }
    static void lifecycle(){
        for(int mode=0;mode<4;mode++){
            Ui ui=fresh();if(mode%2==1)ui.engine.realtime.failure=new IOException("offline");
            ui.shareLink();ui.engine.directoryWorker.drain();require(ui.engine.ui.tasks.size()==1,"callback queued");
            if(mode<2){ui.onPause();cleared(ui);ui.resumed=true;}
            else {ui.onDestroy();cleared(ui);}
            ui.engine.ui.drain();require(ui.sent.isEmpty()&&Toast.messages.isEmpty(),"late success/error after pause+resume/destroy must be ignored");
        }
        Ui ui=fresh();ui.shareLink();ui.engine.directoryWorker.drain();ui.onPause();ui.resumed=true;
        ui.shareLink();ui.engine.ui.drain();require(ui.sharingLink&&!ui.shareLink.enabled,"old callback cleared a new pending share");
        finish(ui);require(ui.sent.size()==1,"new share after resume must succeed");cleared(ui);
        for(String key:new String[]{"account","contact_fingerprint","server_id","active","directory","broken"}){
            ui=fresh();ui.shareLink();ui.engine.directoryWorker.drain();
            JSONObject changed=new JSONObject(ui.latest.toString());
            changed.put(key,key.equals("broken")?true:key.equals("active")||key.equals("directory")?false:"changed");
            ui.changed(changed);cleared(ui);ui.engine.ui.drain();require(ui.sent.isEmpty()&&Toast.messages.isEmpty(),"changed UI context must ignore callback: "+key);
        }
        ui=fresh();ui.shareLink();ui.engine.directoryWorker.drain();ui.latest.put("account","account-b");ui.engine.ui.drain();require(ui.sent.isEmpty(),"callback final context guard");cleared(ui);
        System.out.println("PASS pause/resume/destroy + late success/error + superseded request + UI context changes clear pending and ignore callbacks");
    }
    public static void main(String[] args){
        screenshot();
        if(args.length>0&&args[0].equals("screenshot"))return;
        errors();malformed();trust();ownerContext();lifecycle();
    }
}
'''
    jar = ROOT / 'out/deps/json-20240303.jar'
    if not jar.exists():
        subprocess.run(['python3', str(ROOT / 'dependencies.py')], check=True)
    with tempfile.TemporaryDirectory(prefix='paranoid-share-link-') as tmp:
        java = Path(tmp) / 'ShareLinkTest.java'
        # Use the production exception class/constructor too, with a package import.
        java.write_text('import org.paranoid.text.SyncCycle;\n' + harness)
        subprocess.run(['javac', '--release', '8', '-Xlint:-options', '-encoding', 'UTF-8', '-cp', str(jar), '-d', tmp,
                        str(ROOT / 'src/org/paranoid/text/SyncCycle.java'), str(java)], check=True)
        subprocess.run(['java', '-cp', f'{tmp}:{jar}', 'ShareLinkTest', *sys.argv[1:]], check=True, timeout=30)


if __name__ == '__main__':
    main()
