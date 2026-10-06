#!/usr/bin/env python3
"""REQ-CLIENT-003: execute production update page construction/routing on a JVM.

Production methods are extracted verbatim (the existing lifecycle/worker pattern).
The host view adapter tracks a single parent, attachment to an Activity root and
ancestor visibility, unlike a no-op setVisibility stub. Controller tap/trigger and
status code are production; network, verifier and OS are deterministic adapters.
No sockets, APKs, Android Binder or device/installer acceptance are involved.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent


def between(source, start, end):
    return source[source.index(start):source.index(end, source.index(start))]


def method(source, name):
    # All selected declarations start on their own line. Braces inside strings
    # and comments must not terminate an extracted Java method.
    match = re.search(r'^    (?:@Override )?(?:public|private|protected) [^\n]*?\b' + name + r'\([^\n]*?\)\s*\{', source, re.M)
    if not match:
        raise AssertionError('missing production method: ' + name)
    start = match.start()
    tokens = re.finditer(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|//[^\n]*|/\*[\s\S]*?\*/|[{}]', source[match.end()-1:])
    depth = 0
    for token in tokens:
        if token.group() == '{':
            depth += 1
        elif token.group() == '}':
            depth -= 1
            if depth == 0:
                return source[start:match.end()-1+token.end()]
    raise AssertionError('unclosed production method: ' + name)


def main():
    ui = (ROOT / 'src/org/paranoid/text/MainActivity.java').read_text()
    controller = (ROOT / 'src/org/paranoid/text/UpdateController.java').read_text()
    names = ['buildHeader', 'buildWelcome', 'buildDialogs', 'buildContacts', 'buildIdentity',
             'buildNavigation', 'navigation', 'show', 'selectNavigation', 'showMenu',
             'openUpdates', 'onBackPressed', 'addScrollablePage', 'changed']
    # During the initial RED the page does not exist yet. Once added, execute its
    # exact builder/helper and require onCreate's real call sequence to attach it.
    for optional in ['buildUpdates', 'showUpdates', 'closeUpdates']:
        if re.search(r'private void ' + optional + r'\(', ui):
            names.append(optional)
    construction = between(ui, '        buildHeader();', '        updateLockScreen(')
    create_result = between(ui, '        String install=UpdateController.installStatus(this,getIntent());', '        if(saved==null)')
    new_result = between(ui, '        String install=UpdateController.installStatus(this,intent);', '        handleLink(intent);')
    # Include any new route state as actually initialized by MainActivity.
    route_fields = '\n'.join(line for line in ui.splitlines() if re.match(r'    private String updates\w*=', line))
    controller_methods = between(controller, '    public UpdateController(', '    /** PackageInstaller session')
    controller_fields = between(controller, '    private final Activity activity;', '    public UpdateController(')
    sources = {
        'android/view/View.java': '''package android.view;
import java.util.*;
public class View {
 public static final int VISIBLE=0,GONE=8,IMPORTANT_FOR_ACCESSIBILITY_NO=2;
 public View parent; public final List<View> children=new ArrayList<>();
 public boolean attached,enabled=true; public int visibility=VISIBLE; public String description="";
 public Object tag; public float alpha=1; public OnClickListener click;
 public interface OnClickListener {void onClick(View v);}
 public View(Object context){} public Object getParent(){return parent;}
 public void addView(View child){if(child.parent!=null)throw new AssertionError("two parents");child.parent=this;children.add(child);}
 public void addView(View child,Object params){addView(child);}
 public void setVisibility(int v){visibility=v;} public int getVisibility(){return visibility;}
 public boolean isShown(){return visibility==VISIBLE&&(parent==null?attached:parent.isShown());}
 public boolean descendsFrom(View root){return this==root||(parent!=null&&parent.descendsFrom(root));}
 public void setOnClickListener(OnClickListener l){click=l;}
 public boolean performClick(){if(!enabled||click==null)return false;click.onClick(this);return true;}
 public void setEnabled(boolean v){enabled=v;}public boolean isEnabled(){return enabled;}
 public void setAlpha(float v){alpha=v;}public float getAlpha(){return alpha;}
 public void setTag(Object v){tag=v;}public Object getTag(){return tag;}
 public void setContentDescription(String v){description=v;}
 public void setPadding(int a,int b,int c,int d){}public void setBackground(Object v){}
 public void setBackgroundColor(int v){}public void setMinimumHeight(int v){}
 public void setFocusable(boolean v){}public void requestFocus(){}public void setSelected(boolean v){}
 public void setImportantForAccessibility(int v){}public int getTop(){return 0;}
 public void post(Runnable r){r.run();}
}
''',
        'android/view/Gravity.java': 'package android.view; public class Gravity {public static final int CENTER=1,CENTER_VERTICAL=2;}',
        'android/content/pm/PackageInstaller.java': '''package android.content.pm;
public class PackageInstaller {public static final String EXTRA_STATUS="status",EXTRA_STATUS_MESSAGE="message";
public static final int STATUS_PENDING_USER_ACTION=-1,STATUS_SUCCESS=0;}
''',
    }
    harness = '''import java.util.*;import java.io.*;import java.util.concurrent.atomic.AtomicBoolean;
import android.view.View;import android.view.Gravity;
public class UpdatePageTest {
 static void require(boolean ok,String message){if(!ok)throw new AssertionError(message);}
 static class Queue {final ArrayDeque<Runnable> tasks=new ArrayDeque<>();void execute(Runnable r){tasks.add(r);}
  void drain(){while(!tasks.isEmpty())tasks.remove().run();}}
 static class TextView extends View {String text="";TextView(Object a){super(a);}
  void setText(String s){text=s;}String getText(){return text;}void setTextSize(int n){}void setTextColor(int n){}
  void setMaxLines(int n){}void setEllipsize(Object o){}void setGravity(int n){}void setMinHeight(int n){}
  void setCompoundDrawablesWithIntrinsicBounds(Object a,Object b,Object c,Object d){}void setLineSpacing(int n,float v){}}
 static class Button extends TextView {Button(Object a){super(a);}}
 static class ImageView extends View {ImageView(Object a){super(a);}void setImageDrawable(Object o){}}
 static class ImageButton extends ImageView {ImageButton(Object a){super(a);}}
 static class LinearLayout extends View {LinearLayout(Object a){super(a);}void setGravity(int n){}
  static class LayoutParams {int rightMargin,leftMargin;LayoutParams(int w,int h){}LayoutParams(int w,int h,int weight){}void setMargins(int a,int b,int c,int d){}}}
 static class FrameLayout extends LinearLayout {FrameLayout(Object a){super(a);}}
 static class ScrollView extends LinearLayout {ScrollView(Object a){super(a);}void setFillViewport(boolean b){}
  void setClipToPadding(boolean b){}void smoothScrollTo(int x,int y){}}
 static class Switch extends Button {Switch(Object a){super(a);}void setChecked(boolean b){}
  interface Checked {void changed(Switch v,boolean checked);}void setOnCheckedChangeListener(Checked c){}}
 static class Symbol {Symbol(String n,int c){}}
 static class TextUtils {static class TruncateAt {static final Object END=new Object();}}
 static class Palette {int canvas,surface,text,muted,border,action,actionText,actionSoft,danger;}
 static class JSONObject {Map<String,Object> data=new HashMap<>();JSONObject put(String k,Object v){data.put(k,v);return this;}
  String optString(String k){return optString(k,"");}String optString(String k,String d){return data.get(k) instanceof String?(String)data.get(k):d;}
  boolean optBoolean(String k){return Boolean.TRUE.equals(data.get(k));}long optLong(String k){return 0;}
  JSONObject optJSONObject(String k){return null;}}
 static class Preferences {boolean getBoolean(String k,boolean d){return d;}Preferences edit(){return this;}
  Preferences putBoolean(String k,boolean v){return this;}void apply(){}}
 static class ContactNames {static String title(Object a,String account){return account;}}
 static class Toast {static final int LENGTH_LONG=1;static Toast makeText(Object a,String b,int c){return new Toast();}void show(){}}
 static class BackgroundConnectionService {static boolean running(){return false;}static void requestStop(Object o){}}
 static class TextEngine {interface Directory {void done(Object value,String error);}
  void directoryVisibility(boolean v,Directory cb){}void refreshNicknameProfile(){}}
 static class Drafts {String text(String account){return "";}}
 static class PopupMenu {static PopupMenu shown;final Menu menu=new Menu();interface Click {boolean click(Item item);}Click click;
  PopupMenu(Object a,Object b){}Menu getMenu(){return menu;}void setOnMenuItemClickListener(Click c){click=c;}
  void show(){shown=this;}static class Menu {Map<Integer,Item> items=new HashMap<>();void add(int g,int id,int o,String s){items.put(id,new Item(id));}}
  static class Item {int id;Item(int i){id=i;}int getItemId(){return id;}}
  void select(int id){require(menu.items.containsKey(id),"missing menu action");click.click(menu.items.get(id));shown=null;}}
 static class Intent {static final String ACTION_INSTALL_PACKAGE="install",EXTRA_INTENT="intent";
  static final int FLAG_GRANT_READ_URI_PERMISSION=1;String action;int code;String message="cancelled";Intent confirm;
  Intent(String a){action=a;}Intent(String a,Object uri){action=a;}String getAction(){return action;}
  int getIntExtra(String key,int fallback){return code;}Intent getParcelableExtra(String k){return confirm;}
  String getStringExtra(String k){return message;}Intent setDataAndType(Object uri,String mime){return this;}
  void setClipData(Object clip){}void addFlags(int flags){}void setPackage(String p){}}
 static class Uri {static Uri parse(String s){return new Uri();}}
 static class ClipData {static Object newRawUri(String label,Object uri){return uri;}}
 static class Settings {static final String ACTION_MANAGE_UNKNOWN_APP_SOURCES="permission";}
 static class Build {static class VERSION {static final int SDK_INT=35;}static final String[] SUPPORTED_ABIS={"arm64-v8a"};}
 static class ResolveInfo {ActivityInfo activityInfo=new ActivityInfo();static class ActivityInfo {String packageName="installer";}}
 static class PackageManager {static final int MATCH_DEFAULT_ONLY=1,MATCH_SYSTEM_ONLY=2;
  boolean canRequestPackageInstalls(){return true;}ResolveInfo resolveActivity(Intent i,int flags){return new ResolveInfo();}}
 static class Activity {boolean focus=true;int launches;final Queue ui=new Queue();Intent intent;
  boolean isFinishing(){return false;}boolean isDestroyed(){return false;}boolean hasWindowFocus(){return focus;}
  void runOnUiThread(Runnable r){ui.execute(r);}void revokeUriPermission(Object uri,int flags){}
  File getCacheDir(){return new File("unused-cache");}String getPackageName(){return "global.paranoid.messenger";}
  PackageManager getPackageManager(){return new PackageManager();}void startActivity(Intent i){launches++;}
  public void onBackPressed(){}public void changed(JSONObject v,String m){}Intent getIntent(){return intent;}}
 static class UpdateManifest {String versionName="next";long apkSize=3;}
 // I/O and OS fixtures, NOT replacements for existing integrity/transport tests.
 static class UpdateClient {static int checks,downloads;static boolean failure,available=true;
  UpdateManifest check()throws IOException {checks++;if(failure)throw new IOException("fixture");return available?new UpdateManifest():null;}
  interface Verifier {void verify(File f,UpdateManifest m)throws Exception;}
  File download(UpdateManifest m,File cache,Verifier v)throws Exception {downloads++;File f=new File("unused-verified");v.verify(f,m);return f;}
  static void verifyBytes(File f,UpdateManifest m){}}
 static class UpdatePolicy {static final String URI="fixture-uri";static boolean available(UpdateManifest m,long v,int sdk,String[] abi){return true;}
  static File providerFile(File cache,String uri,String mode){return new File("unused-verified");}}
 static class AndroidUpdateVerifier {static long version(Object installed){return 1;}static Object installed(Activity a){return a;}
  static void verify(Activity a,File f,UpdateManifest m){}}
 static class UpdateController {
  static final Queue WORK=new Queue();static final AtomicBoolean BUSY=new AtomicBoolean();
''' + controller_fields + controller_methods + '''
  private void sessionInstall(File f,String error){throw new AssertionError("unexpected fallback; separately covered by session worker test");}
  static final String INSTALL_STATUS="global.paranoid.messenger.INSTALL_STATUS";
''' + method(controller, 'installStatus') + '''
 }
 static class Ui extends Activity {
  final TextEngine engine=new TextEngine();final Palette colors=new Palette();
  LinearLayout root,header,nav,welcome,contacts,dialogs,identity,updates,chat,contactList,dialogList,history;
  FrameLayout pages;TextView screenTitle,status,chatTrust,myId,fingerprint,draftHint,nickView,loginHint,backgroundHint,updateHint,updateHeading;
  LinearLayout directoryBlock,identityStateBlock;TextView identityStateTitle,identityStateBody;Switch visibleSwitch;
  Button identityStateAction,create,send,share,copy,navChats,navContacts,navIdentity,background,shareLink;
  ImageView qr;ImageButton leading,trailing,menuAction,callAction,videoAction;TextView draft=new TextView(this);
  UpdateController updateController;String page="dialogs",selectedAccount="",displayedQr="",lastStatus="",pendingShareContext="";
  boolean active,hasIdentity,hasBlockchainNick,nicknameReadFailed,broken,restoringDraft,creating,identityLogin,restoringSwitch;
  boolean resumed=true,onboardingOpened,sharingLink;int onboardings,backgroundOffers;
  JSONObject latest=new JSONObject();Drafts drafts=new Drafts();
  static final String UI_PREFS="prefs",VISIBLE_KEY="visible",BACKGROUND_PROMPT_KEY="background";static final int MODE_PRIVATE=0;
''' + route_fields + '''
  void construct(){root=column();root.attached=true;
''' + construction + '''
  }
  void createResult(Intent result){intent=result;
''' + create_result + '''
  }
  void newResult(Intent intent){this.intent=intent;
''' + new_result + '''
  }
''' + '\n'.join(method(ui, name) for name in names) + '''
  void buildChat(){chat=column();pages.addView(chat);}
  void restoreDraft(){}void hideKeyboard(){}void buttons(){}void requestCall(boolean v){}void contactDetails(){}
  void addContact(){}void connectionDetails(){}void enableBackground(){}void shareLink(){}void openDevnet(){}void showAbout(){}
  void openOnboarding(){onboardings++;onboardingOpened=true;}
  void offerBackground(){backgroundOffers++;focus=false;}
  void clearShareLink(){}String shareContext(JSONObject v){return "";}
  void renderLists(){}void renderHistory(boolean v){}void openPendingLink(){}void autoCheckUpdates(){}
  Preferences getSharedPreferences(String n,int mode){return new Preferences();}
  int dp(int v){return v;}LinearLayout column(){return new LinearLayout(this);}LinearLayout row(){return column();}
  LinearLayout.LayoutParams full(){return new LinearLayout.LayoutParams(-1,-2);}
  LinearLayout.LayoutParams box(int w,int h){return new LinearLayout.LayoutParams(w,h);}
  void space(LinearLayout p,int n){p.addView(new View(this));}Object shape(int c,int r){return null;}Object ripple(int c,int r){return null;}
  TextView text(String t,int size,int color,boolean bold){TextView v=new TextView(this);v.setText(t);return v;}
  Button action(String label,Runnable r){return secondary(label,r);}Button secondary(String label,Runnable r){Button b=new Button(this);b.setText(label);b.setOnClickListener(v->r.run());return b;}
  ImageButton iconButton(String name,String label,Runnable r){ImageButton b=new ImageButton(this);b.setContentDescription(label);b.setOnClickListener(v->r.run());return b;}
 }
 static Ui fresh(boolean connected){UpdateController.WORK.tasks.clear();UpdateController.BUSY.set(false);
  UpdateClient.checks=0;UpdateClient.downloads=0;UpdateClient.failure=false;UpdateClient.available=true;
  Ui ui=new Ui();ui.hasIdentity=connected;ui.active=connected;ui.construct();return ui;}
 static void menu(Ui ui){require(ui.menuAction.isShown(),"menu unavailable");ui.menuAction.performClick();PopupMenu.shown.select(1);}
 static void drain(Ui ui){UpdateController.WORK.drain();ui.ui.drain();}
 static void visible(Ui ui){require(ui.updateController.button.isShown(),"update button must be attached and shown after real construction + menu open (parent detached/GONE)");
  require(ui.updateController.status.isShown(),"update status must be attached and shown");}
 static void visibility(){Ui ui=fresh(true);menu(ui);visible(ui);
  require(ui.page.equals("updates"),"dedicated updates route required");
  require(ui.updateController.button.descendsFrom(ui.updates),"controller must belong to updates page");
  require(ui.updates.getParent() instanceof ScrollView,"updates page must scroll");
  require(!ui.updateController.button.descendsFrom(ui.identity),"no updates block on My ID");
  require(!ui.identity.isShown()&&ui.hasWindowFocus(),"updates must be same Activity, no identity block/modal");
  require(ui.leading.isShown()&&ui.leading.description.contains("Назад"),"updates needs accessible toolbar back");
  System.out.println("PASS production construction + menu: attached scrollable updates, visible controls, no My ID block");}
 static void independentFeed(){
  for(boolean connected:new boolean[]{false,true})for(boolean frozen:new boolean[]{false,true}){
   Ui ui=fresh(connected);ui.broken=frozen;menu(ui);visible(ui);drain(ui);
   require(UpdateClient.checks==1&&UpdateClient.downloads==0&&ui.launches==0,"entry must only check independent feed");
   require(ui.screenTitle.text.equals("Обновления")&&!ui.welcome.isShown(),"no-login update page must replace welcome");
   require(ui.onboardings==0&&ui.hasWindowFocus(),"manual public-feed check must not need login or a dialog");
  }
  System.out.println("PASS no-identity/connected/frozen entry checks feed without login, download or install");
 }
 static void backAndReopen(){
  for(String previous:new String[]{"contacts","identity","dialogs","welcome"})
   for(String phase:new String[]{"check","download","install","busy-check","busy-download","busy-install"}){
    Ui ui=fresh(!previous.equals("welcome"));ui.show(previous);
    if(phase.equals("check"))UpdateClient.available=false;
    menu(ui);
    if(!phase.equals("busy-check"))drain(ui);
    if(phase.equals("install")||phase.equals("busy-download")||phase.equals("busy-install")){
     ui.updateController.button.performClick();
     if(!phase.equals("busy-download"))drain(ui);
    }
    if(phase.equals("busy-install"))ui.updateController.button.performClick();
    UpdateController original=ui.updateController;Button button=original.button;TextView status=original.status;
    int stage=original.stage,checks=UpdateClient.checks,downloads=UpdateClient.downloads,launches=ui.launches;
    int queued=UpdateController.WORK.tasks.size();String message=status.text;
    ui.onBackPressed();require(ui.page.equals(previous),"system Back must return to previous page: "+previous+" at "+phase);
    require(!button.isShown(),"closed update page still shown");
    menu(ui);visible(ui);
    require(ui.updateController==original&&original.button==button&&original.status==status,"reopen recreated controller/controls");
    require(original.stage==stage,"reopen advanced/reset stage: "+phase);
    require(UpdateClient.downloads==downloads&&ui.launches==launches,"reopen downloaded/installed automatically");
    if(!phase.equals("check")){
     require(status.text.equals(message),"reopen lost status at "+phase);
     require(UpdateController.WORK.tasks.size()==queued,"reopen queued action at "+phase);
    }else{
     require(UpdateController.WORK.tasks.size()==1,"fresh stage0 reopen may only enqueue check");
     drain(ui);require(UpdateClient.checks==checks+1,"stage0 reopen did not check");
    }
    // Reopening the menu while already on updates must not replace the return route.
    menu(ui);ui.leading.performClick();
    require(ui.page.equals(previous),"toolbar Back/repeated entry lost previous page: "+previous);
   }
  Ui banner=fresh(true);banner.show("dialogs");banner.updateHint.setVisibility(View.VISIBLE);
  banner.updateHint.performClick();visible(banner);
  require(banner.updateHint.getVisibility()==View.GONE,"banner not dismissed on entry");
  require(UpdateController.WORK.tasks.size()==1&&UpdateClient.downloads==0&&banner.launches==0,"banner must only check");
  banner.onBackPressed();require(banner.page.equals("dialogs"),"banner Back route");
  System.out.println("PASS Back/toolbar/repeated menu/banner; same controller at stage0/1/2 and busy check/download/install");
 }
 static void checkStatuses(){
  for(boolean error:new boolean[]{false,true}){
   Ui ui=fresh(false);UpdateClient.available=false;UpdateClient.failure=error;menu(ui);drain(ui);visible(ui);
   require(ui.updateController.stage==0&&ui.updateController.button.isEnabled(),"failed/empty check must permit retry");
   require(ui.updateController.status.text.contains(error?"не прошло проверку":"Обновлений пока нет"),"check outcome not visible");
   require(UpdateClient.downloads==0&&ui.launches==0,"check outcome caused download/install");
  }
  System.out.println("PASS real controller no-update/error status remains visible with retry");
 }
 static void installerResults(){
  for(boolean freshCreate:new boolean[]{true,false})for(boolean connected:new boolean[]{false,true})
   for(int code:new int[]{0,1,-1}){
    Ui ui=fresh(connected);String previous=connected?"contacts":"welcome";ui.show(previous);
    Intent unrelated=new Intent("ordinary");
    if(freshCreate)ui.createResult(unrelated);else ui.newResult(unrelated);
    require(ui.page.equals(previous)&&UpdateController.WORK.tasks.isEmpty(),"ordinary intent opened updates");
    Intent result=new Intent(UpdateController.INSTALL_STATUS);result.code=code;
    if(code==-1)result.confirm=new Intent("system-confirmation");
    if(freshCreate)ui.createResult(result);else ui.newResult(result);
    visible(ui);require(ui.page.equals("updates"),"installer result not on updates page");
    require(ui.updateController.status.text.contains(code==0?"установлено":code==-1?"системном окне":"не выполнена"),"lost installer result");
    require(UpdateClient.checks==0&&UpdateClient.downloads==0&&UpdateController.WORK.tasks.isEmpty(),"installer callback triggered updater action");
    require(ui.launches==(code==-1?1:0),"only the existing pending-user-action confirmation may launch");
    ui.onBackPressed();require(ui.page.equals(previous),"installer result Back must return to previous page");
  }
  Ui ui=fresh(true);ui.show("identity");menu(ui);drain(ui);ui.updateController.button.performClick();drain(ui);
  UpdateController controller=ui.updateController;
  Intent result=new Intent(UpdateController.INSTALL_STATUS);result.code=1;ui.newResult(result);
  require(ui.updateController==controller&&controller.stage==2,"result recreated/reset install-ready controller");
  require(UpdateController.WORK.tasks.isEmpty()&&ui.launches==0,"result auto-installed ready APK");
  ui.leading.performClick();require(ui.page.equals("identity"),"result on open page lost return route");
  System.out.println("PASS onCreate/onNewIntent result display; no check/download/auto-install, native confirmation retained");
 }
 static void profileRepaints(){
  for(boolean initiallyConnected:new boolean[]{false,true})for(boolean connected:new boolean[]{false,true})
   for(boolean frozen:new boolean[]{false,true})for(String state:new String[]{"none","pending","unregistered","loading","unavailable","verified"}){
    Ui ui=fresh(initiallyConnected);ui.show(initiallyConnected?"contacts":"welcome");menu(ui);drain(ui);
    UpdateController original=ui.updateController;String status=original.status.text;
    JSONObject view=new JSONObject().put("nickname_state",state).put("solana_nick",state.equals("verified")?"alice":"")
     .put("identity",connected).put("active",connected).put("identity_login",true).put("broken",frozen);
    ui.changed(view,"profile callback");visible(ui);
    require(ui.page.equals("updates"),"profile repaint hijacked updates: "+state);
    require(ui.onboardings==0&&!ui.onboardingOpened,"async profile opened onboarding over updates: "+state);
    require(ui.backgroundOffers==0&&ui.hasWindowFocus(),"async background offer stole Activity focus");
    require(ui.updateController==original&&original.stage==1&&original.status.text.equals(status),"profile repaint reset updater");
    require(UpdateClient.checks==1&&UpdateClient.downloads==0&&ui.launches==0,"profile repaint triggered updater action");
    // Guard is bounded to the update page; normal profile/onboarding routing resumes after exit.
    ui.onBackPressed();ui.changed(view,"after Back");
    boolean actionable=!connected&&!frozen&&(state.equals("none")||state.equals("pending")||state.equals("unregistered"));
    require(ui.onboardings==(actionable?1:0),"updater guard changed ordinary onboarding");
    if(!connected&&(state.equals("verified")||state.equals("unavailable")))require(ui.page.equals("identity"),"ordinary profile routing lost");
   }
  // Installer text must also survive the first asynchronous profile callback.
  Ui ui=fresh(false);Intent result=new Intent(UpdateController.INSTALL_STATUS);result.code=1;ui.createResult(result);
  String status=ui.updateController.status.text;
  ui.changed(new JSONObject().put("nickname_state","none"),"late initial snapshot");visible(ui);
  require(ui.updateController.status.text.equals(status)&&ui.onboardings==0,"initial profile hid installer result");
  System.out.println("PASS full production changed(): profile/onboarding/background offer cannot hijack updates; ordinary routes retained");
 }
 public static void main(String[] args){visibility();independentFeed();backAndReopen();checkStatuses();installerResults();profileRepaints();}
}
'''
    sources['UpdatePageTest.java'] = harness
    with tempfile.TemporaryDirectory(prefix='paranoid-update-page-') as scratch:
        temp = Path(scratch)
        files = []
        for name, text in sources.items():
            path = temp / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            files.append(str(path))
        subprocess.run(['javac', '--release', '8', '-Xlint:-options', '-encoding', 'UTF-8',
                        '-d', str(temp), *files], check=True, timeout=30)
        subprocess.run(['java', '-cp', str(temp), 'UpdatePageTest', *sys.argv[1:]], check=True, timeout=30)


if __name__ == '__main__':
    main()
