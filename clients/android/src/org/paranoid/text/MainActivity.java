package org.paranoid.text;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.res.Configuration;
import android.content.res.ColorStateList;
import android.graphics.Canvas;
import android.graphics.ColorFilter;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.Editable;
import android.text.InputFilter;
import android.text.TextWatcher;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.view.inputmethod.InputMethodManager;
import android.widget.*;
import org.json.JSONArray;
import org.json.JSONObject;

/** Native Private Orbit messenger. Only committed publicView data becomes a message. */
public final class MainActivity extends Activity implements TextEngine.Listener {
    private TextEngine engine;
    private LinearLayout root,header,nav,welcome,contacts,dialogs,identity,chat,contactList,dialogList,history;
    private ScrollView messageScroll;
    private FrameLayout pages;
    private TextView screenTitle,status,chatTrust,myId,fingerprint,draftHint;
    private ImageView qr;
    private EditText draft;
    private Button create,send,share,copy,navChats,navContacts,navIdentity,background,shareLink;
    private TextView nickView;
    private LinearLayout directoryBlock,identityStateBlock;private Switch visibleSwitch;private boolean restoringSwitch;
    private TextView identityStateTitle,identityStateBody;private Button identityStateAction;
    private static final String VISIBLE_KEY="directory_visible_v1";
    private ImageButton leading,trailing;
    private ImageButton menuAction;
    private ImageButton callAction,videoAction;
    private Button callVideo,callSwitchCamera;
    private FrameLayout videoStage;
    private org.webrtc.SurfaceViewRenderer remoteRenderer,localRenderer;
    private boolean renderersInitialized,videoPausedByBackground,videoCallIntent,waitingForCamera;
    private static final int CAMERA_PERMISSION=97;
    private android.app.Dialog callDialog;
    private TextView callName,callStatus,callTrust,callPrivacy;
    private static final String VIDEO_PRIVACY="Видео и звук защищены сквозным шифрованием: сервер и ретранслятор не могут их расшифровать. Камера включается только по вашему нажатию и выключается, когда приложение свёрнуто. Оператор ретранслятора видит IP-адрес, время и объём трафика; при прямом соединении IP-адрес видит собеседник.";
    private static final String VOICE_PRIVACY="Звук защищён сквозным шифрованием. При соединении через ретранслятор оператор ретранслятора видит ваш IP-адрес, время и объём трафика. Если сервер не поддерживает ретрансляцию, используется прямое соединение: собеседник может видеть ваш IP-адрес. В некоторых сетях прямое соединение недоступно.";
    private Button callAnswer,callEnd,callMute,callSpeaker;
    private String displayedCall="",permissionAccount="",permissionCall="";
    private boolean resumed,permissionAnswer,pendingCallIntent;
    private boolean waitingForMicrophone;
    private boolean lockScreenShown;
    private long callIntentGeneration,callIntentDeadline;
    private Runnable callIntentRetry;
    private static final int MICROPHONE_PERMISSION=95,BLUETOOTH_PERMISSION=96;
    private final TextEngine.CallListener callListener=this::renderCall;
    private String page="dialogs",selectedAccount="",displayedQr="",lastStatus="Открываем сохранённые данные…",renderedHistory="",renderedDialogs="";
    private boolean active=false,hasIdentity=false,hasBlockchainNick=false,nicknameReadFailed=false,broken=false,restoringDraft=false,creating=false,identityLogin=false;
    private TextView loginHint;private boolean onboardingOpened;
    private boolean backgroundPromptShowing;
    private TextView backgroundHint;
    private TextView updateHint,updateHeading;
    private UpdateController updateController;
    private static boolean updateAutoChecked;
    private static final String UI_PREFS="paranoid-ui",BACKGROUND_PROMPT_KEY="background_prompt_v1",
        UPDATE_CHECK_AT_KEY="update_autocheck_at_v1",BLUETOOTH_PROMPT_KEY="bluetooth_prompt_v1";
    private JSONObject latest=new JSONObject();
    private MessagePresentation.Drafts drafts=new MessagePresentation.Drafts();
    private Palette colors;
    private final Handler handler=new Handler(Looper.getMainLooper());
    private final Runnable poll=new Runnable(){public void run(){engine.sync();handler.postDelayed(this,3000);}};

    @Override public void onCreate(Bundle saved) {
        boolean night=(getResources().getConfiguration().uiMode&Configuration.UI_MODE_NIGHT_MASK)==Configuration.UI_MODE_NIGHT_YES;
        setTheme(night?android.R.style.Theme_Material_NoActionBar:android.R.style.Theme_Material_Light_NoActionBar);
        super.onCreate(saved);
        Object retained=getLastNonConfigurationInstance();
        if(retained instanceof Retained){Retained state=(Retained)retained;drafts=state.drafts;page=state.page;selectedAccount=state.account;}
        colors=new Palette(night);
        engine=TextEngine.get(this);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        getWindow().setStatusBarColor(colors.canvas);getWindow().setNavigationBarColor(colors.surface);
        int appearance=colors.dark?0:View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR|View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR;
        getWindow().getDecorView().setSystemUiVisibility(appearance);
        root=column();root.setBackgroundColor(colors.canvas);root.setFocusableInTouchMode(true);setContentView(root);
        if(Build.VERSION.SDK_INT>=30){
            getWindow().setDecorFitsSystemWindows(false);
            root.setOnApplyWindowInsetsListener((v,insets)->{
                android.graphics.Insets system=insets.getInsets(WindowInsets.Type.systemBars());
                android.graphics.Insets keyboard=insets.getInsets(WindowInsets.Type.ime());
                v.setPadding(system.left,system.top,system.right,Math.max(system.bottom,keyboard.bottom));
                return insets;
            });
        }
        buildHeader();
        pages=new FrameLayout(this);root.addView(pages,new LinearLayout.LayoutParams(-1,0,1));
        buildWelcome();buildDialogs();buildContacts();buildIdentity();buildChat();restoreDraft();buildNavigation();
        show(page);
        updateLockScreen(engine.calls().snapshot().optString("state"));
        String install=UpdateController.installStatus(this,getIntent());
        if(install!=null){updateController.showStatus(install);show("identity");}
        if(saved==null)handleLink(getIntent());
        CrashLog.load(this,this::runOnUiThread,report->{
            if(report==null||isFinishing()||isDestroyed())return;
            String crash=report.text;
            android.widget.TextView text=new android.widget.TextView(this);text.setText(crash);text.setTextIsSelectable(true);text.setTextSize(11);
            android.widget.ScrollView scroll=new android.widget.ScrollView(this);scroll.addView(text);int pad=(int)(12*getResources().getDisplayMetrics().density);scroll.setPadding(pad,pad,pad,0);
            new android.app.AlertDialog.Builder(this).setTitle("Отчёт о завершении приложения")
                .setMessage("Проверьте текст перед копированием: отчёт Java может содержать технические данные приложения.").setView(scroll)
                .setPositiveButton("Скопировать",(d,w)->{getSystemService(android.content.ClipboardManager.class).setPrimaryClip(android.content.ClipData.newPlainText("ParanoID crash",crash));CrashLog.acknowledge(this,report);})
                .setNegativeButton("Закрыть",(d,w)->CrashLog.acknowledge(this,report)).setCancelable(false).show();
        });
    }
    @Override protected void onNewIntent(Intent intent){
        super.onNewIntent(intent);
        updateLockScreen(engine.calls().snapshot().optString("state"));
        setIntent(intent);
        String install=UpdateController.installStatus(this,intent);
        if(install!=null){if(updateController!=null)updateController.showStatus(install);show("identity");}
        handleLink(intent);
    }
    /** Over-lock display only while an incoming call rings; never a permanent lock bypass. */
    private void updateLockScreen(String state){
        if(Build.VERSION.SDK_INT<27)return;
        boolean visible=state.equals("incoming");
        if(visible==lockScreenShown)return;lockScreenShown=visible;
        setShowWhenLocked(visible);setTurnScreenOn(visible);
    }

    private void buildHeader(){
        header=column();header.setPadding(dp(12),dp(8),dp(12),dp(8));root.addView(header);
        LinearLayout row=row();row.setGravity(Gravity.CENTER_VERTICAL);header.addView(row);
        leading=iconButton("identity","Мой ID",()->{if(page.equals("chat"))show("dialogs");else show("identity");});
        row.addView(leading,box(48,48));
        screenTitle=text("Чаты",28,colors.text,true);screenTitle.setMaxLines(1);screenTitle.setEllipsize(TextUtils.TruncateAt.END);
        LinearLayout.LayoutParams titleParams=new LinearLayout.LayoutParams(0,-2,1);titleParams.setMargins(dp(8),0,dp(8),0);row.addView(screenTitle,titleParams);
        trailing=iconButton("compose","Добавить контакт",()->{if(page.equals("chat"))contactDetails();else addContact();});
        videoAction=iconButton("video","Видеозвонок",()->requestCall(true));row.addView(videoAction,box(48,48));videoAction.setVisibility(View.GONE);
        callAction=iconButton("phone","Аудиозвонок",()->requestCall(false));row.addView(callAction,box(48,48));callAction.setVisibility(View.GONE);
        row.addView(trailing,box(48,48));
        menuAction=iconButton("more","Меню",this::showMenu);row.addView(menuAction,box(48,48));menuAction.setVisibility(View.GONE);
        LinearLayout rail=row();rail.setGravity(Gravity.CENTER_VERTICAL);rail.setPadding(dp(12),dp(2),dp(8),0);header.addView(rail);
        View orbit=new View(this);orbit.setBackground(shape(colors.action,8));rail.addView(orbit,box(7,7));
        View line=new View(this);line.setBackgroundColor(colors.border);LinearLayout.LayoutParams lineParams=box(24,1);lineParams.setMargins(dp(5),0,dp(7),0);rail.addView(line,lineParams);
        status=text("Открываем данные…",12,colors.muted,false);status.setMaxLines(1);status.setEllipsize(TextUtils.TruncateAt.END);rail.addView(status,new LinearLayout.LayoutParams(0,dp(32),1));status.setGravity(Gravity.CENTER_VERTICAL);
        rail.setMinimumHeight(dp(48));rail.setBackground(ripple(colors.canvas,12));rail.setOnClickListener(v->connectionDetails());rail.setContentDescription("Статус подключения. Подробнее");rail.setFocusable(true);
    }

    private void buildWelcome(){
        welcome=column();welcome.setPadding(dp(24),dp(20),dp(24),dp(24));addScrollablePage(welcome);
        ImageView mark=new ImageView(this);mark.setImageDrawable(new Symbol("identity",colors.action));mark.setPadding(dp(18),dp(18),dp(18),dp(18));mark.setBackground(shape(colors.actionSoft,28));mark.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);welcome.addView(mark,box(88,88));
        TextView title=text("Ваш ID.\nВаши разговоры.",32,colors.text,true);space(welcome,24);welcome.addView(title);
        TextView body=text("Создайте аккаунт без номера телефона и выберите сервер для переписки.",16,colors.muted,false);space(welcome,16);welcome.addView(body);space(welcome,24);
        create=action("Начать",this::openOnboarding);welcome.addView(create,full());
    }

    private void buildDialogs(){
        dialogs=column();dialogs.setPadding(dp(12),dp(8),dp(12),dp(16));addScrollablePage(dialogs);
        updateHint=text("",13,colors.actionText,false);
        updateHint.setPadding(dp(12),dp(10),dp(12),dp(10));updateHint.setMinimumHeight(dp(40));updateHint.setBackground(ripple(colors.canvas,12));
        updateHint.setOnClickListener(v->openUpdates());updateHint.setFocusable(true);
        updateHint.setVisibility(View.GONE);dialogs.addView(updateHint,full());
        loginHint=text("Войдите, чтобы получать сообщения — открыть",13,colors.actionText,false);
        loginHint.setPadding(dp(12),dp(10),dp(12),dp(10));loginHint.setMinimumHeight(dp(40));loginHint.setBackground(ripple(colors.canvas,12));
        loginHint.setOnClickListener(v->openOnboarding());loginHint.setFocusable(true);loginHint.setVisibility(View.GONE);dialogs.addView(loginHint,full());
        backgroundHint=text("Входящие в фоне отключены — включить",13,colors.actionText,false);
        backgroundHint.setPadding(dp(12),dp(10),dp(12),dp(10));backgroundHint.setMinimumHeight(dp(40));backgroundHint.setBackground(ripple(colors.canvas,12));
        backgroundHint.setOnClickListener(v->enableBackground());backgroundHint.setFocusable(true);backgroundHint.setContentDescription("Входящие в фоне отключены. Включить фоновое подключение");
        backgroundHint.setVisibility(View.GONE);dialogs.addView(backgroundHint,full());
        dialogList=column();dialogs.addView(dialogList);
    }

    private void buildContacts(){
        contacts=column();contacts.setPadding(dp(16),dp(8),dp(16),dp(24));addScrollablePage(contacts);
        Button add=action("Добавить контакт",this::addContact);contacts.addView(add,full());space(contacts,12);
        contacts.addView(text("Сканируйте QR или найдите участника сервера по нику.",14,colors.muted,false));space(contacts,20);
        contactList=column();contacts.addView(contactList);
    }

    private void buildIdentity(){
        identity=column();identity.setPadding(dp(20),dp(8),dp(20),dp(24));addScrollablePage(identity);
        // State block: shown when there is no active session (no nick or not logged in)
        identityStateBlock=column();identityStateBlock.setPadding(dp(4),dp(16),dp(4),dp(8));
        identityStateTitle=text("",24,colors.text,true);identityStateBlock.addView(identityStateTitle);
        space(identityStateBlock,12);
        identityStateBody=text("",16,colors.muted,false);identityStateBody.setLineSpacing(0,1.4f);identityStateBlock.addView(identityStateBody);
        space(identityStateBlock,24);
        identityStateAction=action("",this::openOnboarding);identityStateBlock.addView(identityStateAction,full());
        // My ID screen: nik + share link (QR, hash, fingerprint removed — owner decisions 2026-10-05)
        identity.addView(text("Мой ID",24,colors.text,true));space(identity,8);
        nickView=text("",28,colors.text,true);nickView.setGravity(android.view.Gravity.CENTER);identity.addView(nickView,full());
        identity.addView(identityStateBlock,full());
        space(identity,8);

        qr=new ImageView(this);qr.setVisibility(android.view.View.GONE);
        myId=text("",14,colors.text,false);myId.setVisibility(android.view.View.GONE);
        share=action("",()->{});share.setVisibility(android.view.View.GONE);
        copy=secondary("",()->{});copy.setVisibility(android.view.View.GONE);
        directoryBlock=column();identity.addView(directoryBlock,full());directoryBlock.setVisibility(View.GONE);
        directoryBlock.addView(text("Поделитесь ссылкой, чтобы собеседник добавил вас.",14,colors.muted,false));
        space(directoryBlock,8);shareLink=secondary("Поделиться моей ссылкой",this::shareLink);directoryBlock.addView(shareLink,full());
        space(directoryBlock,16);visibleSwitch=new Switch(this);visibleSwitch.setText("Виден в поиске участников");visibleSwitch.setTextColor(colors.text);visibleSwitch.setTextSize(15);visibleSwitch.setMinHeight(dp(48));
        visibleSwitch.setChecked(getSharedPreferences(UI_PREFS,MODE_PRIVATE).getBoolean(VISIBLE_KEY,true));
        visibleSwitch.setOnCheckedChangeListener((button,checked)->{
            if(restoringSwitch)return;visibleSwitch.setEnabled(false);
            engine.directoryVisibility(checked,(result,error)->{
                visibleSwitch.setEnabled(true);
                if(error!=null){restoringSwitch=true;visibleSwitch.setChecked(!checked);restoringSwitch=false;Toast.makeText(this,error,Toast.LENGTH_LONG).show();return;}
                getSharedPreferences(UI_PREFS,MODE_PRIVATE).edit().putBoolean(VISIBLE_KEY,checked).apply();
            });
        });
        directoryBlock.addView(visibleSwitch,full());
        
        fingerprint=text("",12,colors.muted,false);fingerprint.setVisibility(android.view.View.GONE);identity.addView(fingerprint);
        // Background toggle — compact, no paragraph text
        space(identity,24);
        background=secondary("Фоновое подключение",()->{
            if(BackgroundConnectionService.running())BackgroundConnectionService.requestStop(this);
            else enableBackground();
        });identity.addView(background,full());
        // Updates — only the controller, no heading paragraph
        updateHeading=text("",0,colors.muted,false);updateHeading.setVisibility(android.view.View.GONE); // kept for UpdateController reference
        // Update controller — shown only via menu ⋮, not on My ID screen
        LinearLayout updateHolder=column();updateHolder.setVisibility(android.view.View.GONE);
        updateController=new UpdateController(this,engine,updateHolder);
    }

    /** Single opt-in path: user-visible foreground start plus the OPPO-critical battery exception. */
    private void enableBackground(){
        BackgroundConnectionService.requestStart(this);
        if(Build.VERSION.SDK_INT<33||checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)==android.content.pm.PackageManager.PERMISSION_GRANTED)requestBatteryException();
    }
    private void requestBatteryException(){
        try{
            android.os.PowerManager power=(android.os.PowerManager)getSystemService(POWER_SERVICE);
            if(power!=null&&!power.isIgnoringBatteryOptimizations(getPackageName()))
                startActivity(new Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,android.net.Uri.parse("package:"+getPackageName())));
        }catch(RuntimeException unavailable){/* На части прошивок этот системный экран отсутствует; фоновое подключение продолжит работать без исключения. */}
    }
    /** One-time onboarding offer; a later manual switch-off is respected without re-asking. */
    private void offerBackground(){
        if(backgroundPromptShowing||isFinishing()||isDestroyed())return;
        backgroundPromptShowing=true;
        getSharedPreferences(UI_PREFS,MODE_PRIVATE).edit().putBoolean(BACKGROUND_PROMPT_KEY,true).apply();
        new AlertDialog.Builder(this).setTitle("Работа в фоне")
            .setMessage("Разрешить ParanoID поддерживать подключение в фоне? Без этого входящие звонки и сообщения не приходят, пока приложение закрыто. Появится постоянное уведомление.")
            .setPositiveButton("Разрешить",(dialog,which)->enableBackground())
            .setNegativeButton("Не сейчас",null)
            .setOnDismissListener(dialog->backgroundPromptShowing=false).show();
    }

    private void buildChat(){
        chat=column();pages.addView(chat,new FrameLayout.LayoutParams(-1,-1));
        chatTrust=text("Личность не проверена",12,colors.muted,false);chatTrust.setPadding(dp(20),dp(8),dp(20),dp(8));chatTrust.setGravity(Gravity.CENTER);chatTrust.setBackgroundColor(colors.raised);chat.addView(chatTrust,full());
        chatTrust.setOnClickListener(v->contactDetails());chatTrust.setMinimumHeight(dp(48));chatTrust.setFocusable(true);
        messageScroll=new ScrollView(this);messageScroll.setFillViewport(true);messageScroll.setClipToPadding(false);messageScroll.setPadding(dp(12),dp(12),dp(12),dp(12));chat.addView(messageScroll,new LinearLayout.LayoutParams(-1,0,1));
        history=column();history.setGravity(Gravity.BOTTOM);messageScroll.addView(history,new ScrollView.LayoutParams(-1,-2));
        messageScroll.addOnLayoutChangeListener((v,left,top,right,bottom,oldLeft,oldTop,oldRight,oldBottom)->{
            int previousHeight=oldBottom-oldTop;
            if(previousHeight>0&&bottom-top!=previousHeight&&history.getHeight()-previousHeight-messageScroll.getScrollY()<dp(100))
                messageScroll.post(()->messageScroll.scrollTo(0,history.getHeight()));
        });
        LinearLayout compose=column();compose.setPadding(dp(12),dp(8),dp(12),dp(8));compose.setBackgroundColor(colors.surface);chat.addView(compose,full());
        draftHint=text("",12,colors.muted,false);draftHint.setPadding(dp(8),0,dp(8),dp(4));draftHint.setVisibility(View.GONE);compose.addView(draftHint,full());
        LinearLayout line=row();line.setGravity(Gravity.BOTTOM);compose.addView(line,full());
        draft=new EditText(this);draft.setTextColor(colors.text);draft.setHintTextColor(colors.muted);draft.setTextSize(16);draft.setHint("Сообщение");draft.setContentDescription("Сообщение");draft.setMinLines(1);draft.setMaxLines(5);draft.setGravity(Gravity.TOP|Gravity.START);
        draft.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE|android.text.InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        draft.setFilters(new InputFilter[]{new InputFilter.LengthFilter(2048)});draft.setPadding(dp(16),dp(12),dp(16),dp(12));draft.setBackground(shape(colors.raised,24));draft.setMinimumHeight(dp(48));
        LinearLayout.LayoutParams input=new LinearLayout.LayoutParams(0,-2,1);input.setMargins(0,0,dp(8),0);line.addView(draft,input);
        send=action("Отправить",this::sendMessage);send.setText("");send.setCompoundDrawablesWithIntrinsicBounds(null,new Symbol("send",colors.onAction),null,null);send.setContentDescription("Отправить сообщение");send.setPadding(dp(12),dp(10),dp(12),dp(10));line.addView(send,box(52,52));
        draft.addTextChangedListener(new TextWatcher(){public void beforeTextChanged(CharSequence s,int start,int count,int after){}public void onTextChanged(CharSequence s,int start,int before,int count){if(!restoringDraft)drafts.update(selectedAccount,s.toString());buttons();}public void afterTextChanged(Editable value){}});
    }

    private void buildNavigation(){
        nav=row();nav.setPadding(dp(12),dp(6),dp(12),dp(8));nav.setBackgroundColor(colors.surface);root.addView(nav,full());
        navChats=navigation("Чаты","chat",()->show("dialogs"));navContacts=navigation("Контакты","contacts",()->show("contacts"));navIdentity=navigation("Мой ID","identity",()->show("identity"));
    }

    private Button navigation(String title,String icon,Runnable action){
        Button v=secondary(title,action);v.setTextSize(12);v.setMinHeight(dp(64));v.setPadding(dp(4),dp(6),dp(4),dp(6));v.setTag(icon);nav.addView(v,new LinearLayout.LayoutParams(0,-2,1));return v;
    }

    private void show(String next){
        if(!next.equals("chat")){hideKeyboard();root.requestFocus();}
        page=next;
        View[] content={welcome,dialogs,contacts,identity};
        String[] names={"welcome","dialogs","contacts","identity"};
        boolean profileAvailable=hasIdentity||hasBlockchainNick||nicknameReadFailed;
        for(int i=0;i<content.length;i++)((View)content[i].getParent()).setVisibility((!profileAvailable&&i==0)||(profileAvailable&&next.equals(names[i]))?View.VISIBLE:View.GONE);
        chat.setVisibility(hasIdentity&&next.equals("chat")?View.VISIBLE:View.GONE);
        nav.setVisibility(profileAvailable&&!next.equals("chat")?View.VISIBLE:View.GONE);
        boolean inChat=hasIdentity&&next.equals("chat");
        callAction.setVisibility(inChat?View.VISIBLE:View.GONE);videoAction.setVisibility(inChat?View.VISIBLE:View.GONE);
        menuAction.setVisibility(!inChat?View.VISIBLE:View.GONE);
        screenTitle.setText(!profileAvailable?"ParanoID":inChat?ContactNames.title(this,selectedAccount):next.equals("contacts")?"Контакты":next.equals("identity")?"Мой ID":"Чаты");
        screenTitle.setTextSize(inChat?19:28);
        leading.setImageDrawable(new Symbol(inChat?"back":"identity",colors.action));leading.setContentDescription(inChat?"Назад в чаты":"Мой ID");
        leading.setVisibility(profileAvailable?View.VISIBLE:View.GONE);
        trailing.setVisibility(hasIdentity?View.VISIBLE:View.GONE);trailing.setImageDrawable(new Symbol(inChat?"more":"compose",colors.action));trailing.setContentDescription(inChat?"Сведения о контакте":"Добавить контакт");
        selectNavigation(navChats,next.equals("dialogs"));selectNavigation(navContacts,next.equals("contacts"));selectNavigation(navIdentity,next.equals("identity"));
        buttons();
    }

    private void selectNavigation(Button button,boolean selected){button.setSelected(selected);button.setTextColor(selected?colors.actionText:colors.muted);button.setBackground(ripple(selected?colors.actionSoft:colors.surface,20));button.setCompoundDrawablesWithIntrinsicBounds(null,new Symbol((String)button.getTag(),selected?colors.action:colors.muted),null,null);}

    /** Programmatic ⋮ menu: explicit update check and an about dialog only. */
    private void showMenu(){
        PopupMenu menu=new PopupMenu(this,menuAction);
        menu.getMenu().add(0,1,0,"Проверить обновления");
        menu.getMenu().add(0,2,1,"О приложении");
        if(hasIdentity)menu.getMenu().add(0,3,2,"Ник в Devnet");
        menu.setOnMenuItemClickListener(item->{
            if(item.getItemId()==1)openUpdates();else if(item.getItemId()==3)openDevnet();else showAbout();
            return true;
        });
        menu.show();
    }
    private void openOnboarding(){
        String nicknameState=latest.optString("nickname_state","loading");
        if(!hasIdentity&&("loading".equals(nicknameState)||"unavailable".equals(nicknameState)))return;
        onboardingOpened=true;startActivity(new Intent(this,org.paranoid.devnet.OnboardingActivity.class));
    }
    private void openDevnet(){
        if(engine.calls().active()){Toast.makeText(this,"Завершите звонок перед регистрацией ника",Toast.LENGTH_LONG).show();return;}
        startActivity(new Intent(this,org.paranoid.devnet.MainActivity.class));
    }
    private void showAbout(){
        String version="";try{version=getPackageManager().getPackageInfo(getPackageName(),0).versionName;}catch(Exception ignored){}
        String fp=latest.optString("contact_fingerprint","");if(fp.isEmpty())fp="появится после регистрации";
        new AlertDialog.Builder(this).setTitle("О приложении")
            .setMessage("ParanoID · версия "+version+"\n\nЗакрытая альфа, только тестовые сообщения.")
            .setPositiveButton("Закрыть",null).show();
    }
    /** Opens the existing update block; downloading and verification stay in UpdateController. */
    private void openUpdates(){
        if(!hasIdentity||broken)return;
        if(updateHint!=null)updateHint.setVisibility(View.GONE);
        show("identity");
        if(updateHeading!=null&&identity.getParent() instanceof ScrollView){
            ScrollView scroll=(ScrollView)identity.getParent();
            scroll.post(()->scroll.smoothScrollTo(0,updateHeading.getTop()));
        }
        if(updateController!=null)updateController.trigger();
    }
    /** Silent startup check: once per process, at most every six hours, only after registration. */
    private void autoCheckUpdates(){
        if(updateAutoChecked||broken||!hasIdentity||!active)return;
        updateAutoChecked=true;
        long last=getSharedPreferences(UI_PREFS,MODE_PRIVATE).getLong(UPDATE_CHECK_AT_KEY,0);
        if(System.currentTimeMillis()-last<6*60*60*1000L)return;
        engine.updateTrust(trust->{
            if(trust==null||isFinishing()||isDestroyed())return;
            new Thread(()->{
                try{
                    UpdateManifest found=new UpdateClient().check();
                    boolean availableNow=found!=null&&UpdatePolicy.available(found,
                        AndroidUpdateVerifier.version(AndroidUpdateVerifier.installed(this)),Build.VERSION.SDK_INT,Build.SUPPORTED_ABIS);
                    getSharedPreferences(UI_PREFS,MODE_PRIVATE).edit().putLong(UPDATE_CHECK_AT_KEY,System.currentTimeMillis()).apply();
                    if(availableNow)runOnUiThread(()->{
                        if(isFinishing()||isDestroyed()||updateHint==null)return;
                        updateHint.setText("Доступна версия "+found.versionName+" — обновить");
                        updateHint.setContentDescription("Доступна версия "+found.versionName+". Открыть обновление");
                        updateHint.setVisibility(View.VISIBLE);
                    });
                }catch(Exception ignored){/* Тихая проверка: сетевые ошибки не показываются. */}
            },"paranoid-update-autocheck").start();
        });
    }

    private void openChat(String account){
        // The missed-call notice has done its job once the chat it points at is open.
        VoiceCallService.clearMissed(this);
        selectedAccount=account;restoreDraft();renderedHistory="";show("chat");renderHistory(true);
    }
    private void restoreDraft(){restoringDraft=true;draft.setText(drafts.text(selectedAccount));draft.setSelection(draft.length());restoringDraft=false;}
    private void sendMessage(){
        JSONObject selected=selectedDialog();
        if(!DialogPolicy.canReply(selected,active,broken,drafts.sending())||!MessagePresentation.canSend(draft.getText().toString()))return;
        drafts.update(selectedAccount,draft.getText().toString());MessagePresentation.Ticket ticket=drafts.ticket(selectedAccount);
        drafts.started(ticket);buttons();
        engine.send(ticket.account,ticket.text,committed->{
            drafts.finished(ticket,committed);if(selectedAccount.equals(ticket.account))restoreDraft();buttons();
        });
    }
    private JSONObject selectedDialog(){
        JSONArray entries=latest.optJSONArray("dialogs");
        if(entries!=null)for(int n=0;n<entries.length();n++){JSONObject dialog=entries.optJSONObject(n);if(dialog!=null&&dialog.optString("account").equals(selectedAccount))return dialog;}
        return null;
    }
    private void buttons(){
        if(send==null)return;
        String nicknameState=latest.optString("nickname_state","loading");
        create.setEnabled(!hasIdentity&&!broken&&("none".equals(nicknameState)||"pending".equals(nicknameState)||"unregistered".equals(nicknameState)));create.setAlpha(create.isEnabled()?1f:.45f);
        create.setText("loading".equals(nicknameState)?"Проверяем сохранённый ник…":"Начать");
        share.setEnabled(active&&!displayedQr.isEmpty()&&!broken);copy.setEnabled(share.isEnabled());share.setAlpha(share.isEnabled()?1f:.45f);copy.setAlpha(copy.isEnabled()?1f:.45f);
        JSONObject dialog=selectedDialog();boolean allowed=DialogPolicy.canReply(dialog,active,broken,drafts.sending());
        callAction.setEnabled(allowed||engine.calls().active());callAction.setAlpha(callAction.isEnabled()?1f:.45f);
        videoAction.setEnabled(callAction.isEnabled());videoAction.setAlpha(callAction.getAlpha());
        send.setEnabled(allowed&&MessagePresentation.canSend(draft.getText().toString()));send.setAlpha(send.isEnabled()?1f:.45f);
        boolean blocked=dialog!=null&&dialog.optBoolean("blocked");draft.setEnabled(!broken&&!blocked);
        int bytes=MessagePresentation.byteCount(draft.getText().toString());
        String hint=blocked?"Контакт заблокирован. Откройте сведения, чтобы разблокировать.":broken?"Локальное хранение недоступно. Сообщения не отправляются.":bytes>2048?"Сообщение слишком длинное: "+bytes+" из 2048 байт.":drafts.sending()?"Сохраняем сообщение…":"";
        draftHint.setText(hint);draftHint.setTextColor(bytes>2048?colors.danger:colors.muted);draftHint.setVisibility(hint.isEmpty()?View.GONE:View.VISIBLE);
    }

    private void requestCall(boolean video){
        if(engine.calls().active()){showCall();return;}
        JSONObject selected=selectedDialog();
        if(!DialogPolicy.canReply(selected,active,broken,false))return;
        final String account=selectedAccount;
        new AlertDialog.Builder(this).setTitle(video?"Видеозвонок собеседнику?":"Позвонить собеседнику?")
            .setMessage(video?VIDEO_PRIVACY:VOICE_PRIVACY)
            .setPositiveButton(video?"Видеозвонок":"Позвонить",(dialog,which)->{videoCallIntent=video;requestMicrophone(account,false);}).setNegativeButton("Отмена",null).show();
    }
    /** Explicit camera toggle during a call. CAMERA is requested only here, never on ring or call start. */
    private void toggleVideo(){
        if(!engine.calls().active())return;
        boolean on=!engine.calls().snapshot().optBoolean("local_video");
        if(on&&checkSelfPermission(android.Manifest.permission.CAMERA)!=android.content.pm.PackageManager.PERMISSION_GRANTED){
            waitingForCamera=true;requestPermissions(new String[]{android.Manifest.permission.CAMERA},CAMERA_PERMISSION);return;
        }
        engine.calls().video(on);
    }
    private void requestMicrophone(String account,boolean answer){
        cancelCallIntent();
        permissionAccount=account;permissionAnswer=answer;permissionCall=engine.calls().snapshot().optString("call_id");
        if(checkSelfPermission(android.Manifest.permission.RECORD_AUDIO)!=android.content.pm.PackageManager.PERMISSION_GRANTED){
            waitingForMicrophone=true;
            // BLUETOOTH_CONNECT is requested alongside but never blocks the call when denied.
            java.util.List<String> wanted=new java.util.ArrayList<>();wanted.add(android.Manifest.permission.RECORD_AUDIO);
            if(Build.VERSION.SDK_INT>=31&&checkSelfPermission(android.Manifest.permission.BLUETOOTH_CONNECT)!=android.content.pm.PackageManager.PERMISSION_GRANTED)wanted.add(android.Manifest.permission.BLUETOOTH_CONNECT);
            if(videoCallIntent&&!answer&&checkSelfPermission(android.Manifest.permission.CAMERA)!=android.content.pm.PackageManager.PERMISSION_GRANTED)wanted.add(android.Manifest.permission.CAMERA);
            requestPermissions(wanted.toArray(new String[0]),MICROPHONE_PERMISSION);return;
        }
        if(videoCallIntent&&!answer&&checkSelfPermission(android.Manifest.permission.CAMERA)!=android.content.pm.PackageManager.PERMISSION_GRANTED){
            waitingForMicrophone=true;requestPermissions(new String[]{android.Manifest.permission.CAMERA},MICROPHONE_PERMISSION);return;
        }
        if(Build.VERSION.SDK_INT>=31&&checkSelfPermission(android.Manifest.permission.BLUETOOTH_CONNECT)!=android.content.pm.PackageManager.PERMISSION_GRANTED
            &&!getSharedPreferences(UI_PREFS,MODE_PRIVATE).getBoolean(BLUETOOTH_PROMPT_KEY,false)){
            getSharedPreferences(UI_PREFS,MODE_PRIVATE).edit().putBoolean(BLUETOOTH_PROMPT_KEY,true).apply();
            requestPermissions(new String[]{android.Manifest.permission.BLUETOOTH_CONNECT},BLUETOOTH_PERMISSION);
        }
        queueCallIntent();
    }
    private void cancelCallIntent(){
        callIntentGeneration++;pendingCallIntent=false;
        if(callIntentRetry!=null)handler.removeCallbacks(callIntentRetry);callIntentRetry=null;
    }
    private void queueCallIntent(){
        waitingForMicrophone=false;pendingCallIntent=true;
        callIntentDeadline=android.os.SystemClock.elapsedRealtime()+10000;completeCallIntent();
    }
    private void completeCallIntent(){
        if(!pendingCallIntent||!resumed)return;
        if(broken||checkSelfPermission(android.Manifest.permission.RECORD_AUDIO)!=android.content.pm.PackageManager.PERMISSION_GRANTED){cancelCallIntent();return;}
        if(android.os.SystemClock.elapsedRealtime()>=callIntentDeadline){
            cancelCallIntent();Toast.makeText(this,"Нет подключения для звонка. Повторите после восстановления связи.",Toast.LENGTH_LONG).show();return;
        }
        final boolean answer=permissionAnswer;final String account=permissionAccount,callId=permissionCall;
        if(answer&&(!engine.calls().snapshot().optString("state").equals("incoming")||!engine.calls().snapshot().optString("call_id").equals(callId))){cancelCallIntent();return;}
        if(!answer&&engine.calls().active()){cancelCallIntent();return;}
        final long intentGeneration=callIntentGeneration;
        if(!engine.calls().connected()){
            if(callIntentRetry!=null)handler.removeCallbacks(callIntentRetry);
            callIntentRetry=()->{if(intentGeneration==callIntentGeneration)completeCallIntent();};
            handler.postDelayed(callIntentRetry,100);return;
        }
        pendingCallIntent=false;if(callIntentRetry!=null)handler.removeCallbacks(callIntentRetry);callIntentRetry=null;
        VoiceCallService.begin(this,()->{
            if(!resumed||intentGeneration!=callIntentGeneration||android.os.SystemClock.elapsedRealtime()>=callIntentDeadline){VoiceCallService.stop(this);return;}
            if(answer){if(engine.calls().snapshot().optString("call_id").equals(callId))engine.calls().answer(true);}
            else {boolean video=videoCallIntent&&checkSelfPermission(android.Manifest.permission.CAMERA)==android.content.pm.PackageManager.PERMISSION_GRANTED;videoCallIntent=false;engine.calls().start(account,true,video);}
        });
    }
    private void showCall(){
        if(callDialog!=null&&callDialog.isShowing())return;
        hideKeyboard();
        callDialog=new android.app.Dialog(this,colors.dark?android.R.style.Theme_Material_NoActionBar:android.R.style.Theme_Material_Light_NoActionBar);
        ScrollView scroll=new ScrollView(this);scroll.setFillViewport(true);scroll.setBackgroundColor(colors.canvas);
        LinearLayout body=column();body.setGravity(Gravity.CENTER_HORIZONTAL);body.setPadding(dp(24),dp(24),dp(24),dp(24));scroll.addView(body,new ScrollView.LayoutParams(-1,-1));
        TextView heading=text("Звонок",14,colors.muted,true);heading.setGravity(Gravity.CENTER);body.addView(heading,full());space(body,16);
        // Video stage: remote full-frame, local picture-in-picture. Hidden until any video flows.
        videoStage=new FrameLayout(this);videoStage.setBackgroundColor(0xff000000);videoStage.setVisibility(View.GONE);
        remoteRenderer=new org.webrtc.SurfaceViewRenderer(this);localRenderer=new org.webrtc.SurfaceViewRenderer(this);renderersInitialized=false;
        videoStage.addView(remoteRenderer,new FrameLayout.LayoutParams(-1,-1));
        FrameLayout.LayoutParams pip=new FrameLayout.LayoutParams(dp(96),dp(128),Gravity.TOP|Gravity.END);pip.setMargins(dp(8),dp(8),dp(8),dp(8));videoStage.addView(localRenderer,pip);
        LinearLayout.LayoutParams stage=new LinearLayout.LayoutParams(-1,dp(320));stage.setMargins(0,0,0,dp(16));body.addView(videoStage,stage);
        ImageView orbit=new ImageView(this);orbit.setImageDrawable(new Symbol("identity",colors.action));orbit.setBackground(shape(colors.actionSoft,80));orbit.setPadding(dp(32),dp(32),dp(32),dp(32));orbit.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);body.addView(orbit,box(144,144));space(body,24);
        orbit.setTag("orbit");
        callName=text("",26,colors.text,true);callName.setGravity(Gravity.CENTER);body.addView(callName,full());space(body,12);
        callStatus=text("",18,colors.muted,false);callStatus.setGravity(Gravity.CENTER);callStatus.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);body.addView(callStatus,full());space(body,12);
        callTrust=text("",13,colors.muted,false);callTrust.setGravity(Gravity.CENTER);body.addView(callTrust,full());space(body,24);
        callPrivacy=text(VOICE_PRIVACY,14,colors.muted,false);body.addView(callPrivacy,full());space(body,12);
        callAnswer=action("Ответить",()->requestMicrophone(engine.calls().snapshot().optString("account"),true));body.addView(callAnswer,full());space(body,12);
        LinearLayout controls=row();body.addView(controls,full());
        callMute=secondary("Выключить микрофон",()->engine.calls().mute(!engine.calls().snapshot().optBoolean("muted")));
        callSpeaker=secondary("Громкая связь",()->engine.calls().speaker(!engine.calls().snapshot().optBoolean("speaker")));
        LinearLayout.LayoutParams left=new LinearLayout.LayoutParams(0,-2,1);left.rightMargin=dp(6);controls.addView(callMute,left);
        LinearLayout.LayoutParams right=new LinearLayout.LayoutParams(0,-2,1);right.leftMargin=dp(6);controls.addView(callSpeaker,right);space(body,12);
        LinearLayout videoControls=row();body.addView(videoControls,full());
        callVideo=secondary("Включить камеру",this::toggleVideo);callSwitchCamera=secondary("Сменить камеру",()->{if(engine.media()!=null)engine.media().switchCamera();});
        LinearLayout.LayoutParams vl=new LinearLayout.LayoutParams(0,-2,1);vl.rightMargin=dp(6);videoControls.addView(callVideo,vl);
        LinearLayout.LayoutParams vr=new LinearLayout.LayoutParams(0,-2,1);vr.leftMargin=dp(6);videoControls.addView(callSwitchCamera,vr);space(body,16);
        callEnd=secondary("Завершить",()->{if(engine.calls().snapshot().optString("state").equals("incoming"))engine.calls().reject();else if(engine.calls().active())engine.calls().hangup();else callDialog.dismiss();});
        callEnd.setTextColor(colors.dark?colors.canvas:0xffffffff);callEnd.setBackground(ripple(colors.danger,24));body.addView(callEnd,full());space(body,12);
        body.addView(secondary("К переписке",()->callDialog.dismiss()),full());space(body,24);
        TextView note=text("До ответа микрофон входящего звонка выключен. Звук защищён сквозным шифрованием.",12,colors.muted,false);note.setGravity(Gravity.CENTER);body.addView(note,full());
        callDialog.setContentView(scroll);callDialog.setOnDismissListener(dialog->{releaseRenderers();callDialog=null;});
        // FLAG_SECURE removed from call dialog: owner allows screenshots in all modes (2026-10-05)
        callDialog.show();
        if(Build.VERSION.SDK_INT>=30){
            callDialog.getWindow().setDecorFitsSystemWindows(false);
            scroll.setOnApplyWindowInsetsListener((view,insets)->{
                android.graphics.Insets bars=insets.getInsets(WindowInsets.Type.systemBars());
                view.setPadding(bars.left,bars.top,bars.right,bars.bottom);return insets;
            });
            scroll.requestApplyInsets();
        }
        callDialog.getWindow().getDecorView().setSystemUiVisibility(colors.dark?0:View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR|View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        callDialog.getWindow().setLayout(-1,-1);callDialog.getWindow().setStatusBarColor(colors.canvas);callDialog.getWindow().setNavigationBarColor(colors.canvas);
        renderCall(engine.calls().snapshot());
    }
    private static String callLabel(JSONObject value){
        if(value.optBoolean("reconnecting"))return "Восстанавливаем соединение…";
        String state=value.optString("state");
        if(state.equals("starting"))return "Проверяем доступность…";
        if(state.equals("authorizing"))return "Подготавливаем защищённое соединение…";
        if(state.equals("outgoing"))return "Вызываем…";
        if(state.equals("incoming"))return "Входящий звонок";
        if(state.equals("connecting"))return "Устанавливаем соединение…";
        if(state.equals("connected")){
            long seconds=value.optLong("elapsed_ms")/1000;
            String kind=value.optBoolean("local_video")||value.optBoolean("remote_video")?"Видео":"Соединение установлено";
            return String.format(java.util.Locale.ROOT,"%02d:%02d · %s",seconds/60,seconds%60,kind);
        }
        if(state.equals("reconnecting"))return "Восстанавливаем соединение…";
        String reason=value.optString("reason");
        if(reason.equals("busy"))return "Собеседник занят";
        if(reason.equals("reject"))return "Звонок отклонён";
        if(reason.equals("timeout"))return "Нет ответа или связь потеряна";
        if(reason.equals("failed")||reason.equals("unavailable"))return "Не удалось установить связь";
        if(reason.equals("cancel"))return "Вызов отменён";
        return "Звонок завершён";
    }
    private void renderCall(JSONObject value){
        if(isFinishing()||isDestroyed())return;
        String state=value.optString("state"),id=value.optString("call_id");
        updateLockScreen(state);
        if(resumed&&engine.calls().active()&&!id.equals(displayedCall)){displayedCall=id;showCall();}
        if(callDialog==null)return;
        callName.setText(ContactNames.title(this,value.optString("account")));callStatus.setText(callLabel(value));
        JSONObject peer=null;JSONArray entries=latest.optJSONArray("dialogs");if(entries!=null)for(int n=0;n<entries.length();n++){JSONObject item=entries.optJSONObject(n);if(item!=null&&item.optString("account").equals(value.optString("account")))peer=item;}
        callTrust.setText(peer==null?"Личность не проверена":DialogPolicy.trustLabel(peer));
        callAnswer.setVisibility(state.equals("incoming")?View.VISIBLE:View.GONE);
        callPrivacy.setVisibility(state.equals("incoming")?View.VISIBLE:View.GONE);
        boolean live=value.optBoolean("media_active")||state.equals("authorizing");callMute.setEnabled(live);callSpeaker.setEnabled(live);
        callMute.setText(value.optBoolean("muted")?"Включить микрофон":"Выключить микрофон");callMute.setSelected(value.optBoolean("muted"));
        callSpeaker.setText(value.optBoolean("speaker")?"Телефонный динамик":"Громкая связь");callSpeaker.setSelected(value.optBoolean("speaker"));
        boolean localVideo=value.optBoolean("local_video"),remoteVideo=value.optBoolean("remote_video");
        callVideo.setEnabled(live);callVideo.setText(localVideo?"Выключить камеру":"Включить камеру");callVideo.setSelected(localVideo);
        callSwitchCamera.setEnabled(localVideo);callSwitchCamera.setAlpha(localVideo?1f:.45f);
        boolean showStage=live&&(localVideo||remoteVideo);
        if(showStage)attachRenderers();
        videoStage.setVisibility(showStage?View.VISIBLE:View.GONE);localRenderer.setVisibility(localVideo?View.VISIBLE:View.GONE);
        // Owner request 2026-09-12: the screen must not time out while video is shown. Bound to the call window only,
        // so it ends with the call view; audio-only calls keep the system timeout (proximity handles the earpiece case).
        if(showStage)callDialog.getWindow().addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        else callDialog.getWindow().clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        View orbit=callDialog.findViewById(android.R.id.content).findViewWithTag("orbit");if(orbit!=null)orbit.setVisibility(showStage?View.GONE:View.VISIBLE);
        if(!live)releaseRenderers();
        callEnd.setText(state.equals("incoming")?"Отклонить":engine.calls().active()?"Завершить":"Закрыть");
    }

    private void addContact(){
        if(!hasIdentity||broken)return;
        // RFC-0028: search exists only on an identity-v3 server; older servers keep QR/paste only.
        boolean directory=latest.optBoolean("directory");
        String[] items=directory?new String[]{"Найти на сервере","Сканировать QR","Вставить контакт"}:new String[]{"Сканировать QR","Вставить контакт"};
        new AlertDialog.Builder(this).setTitle("Добавить контакт")
            .setItems(items,(dialog,which)->{
                int choice=directory?which:which+1;
                if(choice==0)openDirectory("");
                else if(choice==1)startActivityForResult(new Intent(this,QrScanActivity.class),45);else pasteContact();
            }).setNegativeButton("Отмена",null).show();
    }

    // RFC-0028 server member directory: one screen, a search field and the list. An empty query
    // lists everyone visible. Tapping a member verifies it (core owner proof + Solana registry)
    // before «Добавить @ник?». Each search spends one of 60 hourly requests, so it runs only on
    // an explicit action, never on every keystroke.
    private android.app.Dialog directoryDialog;
    private LinearLayout directoryList;
    private TextView directoryStatus;
    private Button directoryMore;
    private String directoryQuery="",directoryNext=null;
    private void openDirectory(String initial){
        if(!latest.optBoolean("directory")){Toast.makeText(this,"Этот сервер не поддерживает поиск участников.",Toast.LENGTH_LONG).show();return;}
        if(directoryDialog!=null&&directoryDialog.isShowing())directoryDialog.dismiss();
        directoryDialog=new android.app.Dialog(this,colors.dark?android.R.style.Theme_Material_NoActionBar:android.R.style.Theme_Material_Light_NoActionBar);
        LinearLayout body=column();body.setBackgroundColor(colors.canvas);body.setPadding(dp(16),dp(16),dp(16),dp(8));
        LinearLayout top=row();top.setGravity(Gravity.CENTER_VERTICAL);body.addView(top,full());
        top.addView(iconButton("back","Назад",()->directoryDialog.dismiss()),box(48,48));
        TextView title=text("Найти на сервере",22,colors.text,true);LinearLayout.LayoutParams tp=new LinearLayout.LayoutParams(0,-2,1);tp.leftMargin=dp(8);top.addView(title,tp);
        space(body,12);
        LinearLayout line=row();line.setGravity(Gravity.CENTER_VERTICAL);body.addView(line,full());
        EditText field=new EditText(this);field.setSingleLine(true);field.setTextSize(16);field.setTextColor(colors.text);field.setHintTextColor(colors.muted);
        field.setHint("Ник или его начало");field.setContentDescription("Ник или его начало");field.setText(initial);
        field.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS|android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD);
        field.setFilters(new InputFilter[]{new InputFilter.LengthFilter(24)});field.setImeOptions(android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH);
        field.setPadding(dp(16),dp(12),dp(16),dp(12));field.setBackground(shape(colors.raised,24));field.setMinimumHeight(dp(48));
        LinearLayout.LayoutParams fp=new LinearLayout.LayoutParams(0,-2,1);fp.rightMargin=dp(8);line.addView(field,fp);
        Runnable run=()->{String q=field.getText().toString().trim().toLowerCase(java.util.Locale.ROOT);
            if(!q.matches("([a-z][a-z0-9_]{0,23})?")){directoryStatus.setText("Ник состоит из латинских букв, цифр и «_» и начинается с буквы.");return;}
            hideKeyboard(field);searchDirectory(q,null);};
        line.addView(action("Найти",run),new LinearLayout.LayoutParams(-2,-2));
        field.setOnEditorActionListener((v,id,event)->{run.run();return true;});
        space(body,8);
        directoryStatus=text("",13,colors.muted,false);directoryStatus.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);body.addView(directoryStatus,full());
        space(body,8);
        ScrollView scroll=new ScrollView(this);scroll.setFillViewport(true);body.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
        LinearLayout content=column();scroll.addView(content,new ScrollView.LayoutParams(-1,-2));
        directoryList=column();content.addView(directoryList,full());
        directoryMore=secondary("Показать ещё",()->searchDirectory(directoryQuery,directoryNext));directoryMore.setVisibility(View.GONE);space(content,8);content.addView(directoryMore,full());
        directoryDialog.setContentView(body);directoryDialog.setOnDismissListener(d->{directoryDialog=null;directoryList=null;});
        directoryDialog.show();
        if(Build.VERSION.SDK_INT>=30){
            directoryDialog.getWindow().setDecorFitsSystemWindows(false);
            body.setOnApplyWindowInsetsListener((v,insets)->{android.graphics.Insets bars=insets.getInsets(WindowInsets.Type.systemBars()|WindowInsets.Type.ime());v.setPadding(dp(16)+bars.left,dp(16)+bars.top,dp(16)+bars.right,dp(8)+bars.bottom);return insets;});
        }
        searchDirectory(initial,null);
    }
    private void hideKeyboard(View view){((InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(view.getWindowToken(),0);}
    private void searchDirectory(String query,String after){
        if(directoryList==null)return;
        directoryQuery=query;directoryStatus.setText("Ищем…");directoryMore.setEnabled(false);
        engine.directorySearch(query,after,(result,error)->{
            if(directoryList==null||isFinishing()||isDestroyed())return;
            directoryMore.setEnabled(true);
            if(error!=null){directoryStatus.setText(error);return;}
            if(after==null)directoryList.removeAllViews();
            JSONArray members=result.optJSONArray("members");int shown=members==null?0:members.length();
            for(int n=0;n<shown;n++){JSONObject m=members.optJSONObject(n);if(m!=null)directoryRow(m);}
            directoryNext=result.isNull("next")?null:result.optString("next",null);
            directoryMore.setVisibility(directoryNext==null?View.GONE:View.VISIBLE);
            JSONObject me=result.optJSONObject("me");
            if(me!=null&&visibleSwitch!=null&&visibleSwitch.isEnabled()&&visibleSwitch.isChecked()!=me.optBoolean("visible",true)){
                // The server is the source of truth for visibility; keep the setting in step.
                restoringSwitch=true;visibleSwitch.setChecked(me.optBoolean("visible",true));restoringSwitch=false;
                getSharedPreferences(UI_PREFS,MODE_PRIVATE).edit().putBoolean(VISIBLE_KEY,me.optBoolean("visible",true)).apply();
            }
            String hidden=me!=null&&!me.optBoolean("visible",true)?" Вы скрыты из поиска.":"";
            if(directoryList.getChildCount()==0)directoryStatus.setText((query.isEmpty()?"На этом сервере пока никого не видно.":"Никого с ником на «"+query+"».")+hidden);
            else directoryStatus.setText((query.isEmpty()?"Участники этого сервера":"Найдено по «"+query+"»")+". Нажмите, чтобы проверить и добавить."+hidden);
        });
    }
    private void directoryRow(JSONObject member){
        String name=member.optString("name");
        LinearLayout row=row();row.setGravity(Gravity.CENTER_VERTICAL);row.setPadding(dp(12),dp(12),dp(12),dp(12));row.setMinimumHeight(dp(64));row.setBackground(ripple(colors.canvas,18));row.setFocusable(true);
        TextView avatar=text(name.substring(0,Math.min(2,name.length())).toUpperCase(java.util.Locale.ROOT),16,colors.actionText,true);avatar.setGravity(Gravity.CENTER);avatar.setBackground(shape(colors.actionSoft,24));avatar.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);row.addView(avatar,box(44,44));
        TextView label=text("@"+name,16,colors.text,true);LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(0,-2,1);lp.leftMargin=dp(12);row.addView(label,lp);
        row.setContentDescription("@"+name+". Проверить и добавить");
        row.setOnClickListener(v->checkMember(member));
        directoryList.addView(row,full());
    }
    /** Verify first (core owner proof + Solana registry), then ask, then pair unverified. */
    private void checkMember(JSONObject member){
        String name=member.optString("name");
        if(directoryStatus!=null)directoryStatus.setText("Проверяем @"+name+" в Solana…");
        engine.verifyFound(member,(verified,error)->{
            if(isFinishing()||isDestroyed())return;
            if(error!=null){if(directoryStatus!=null)directoryStatus.setText(error);else Toast.makeText(this,error,Toast.LENGTH_LONG).show();return;}
            if(directoryStatus!=null)directoryStatus.setText("@"+name+" подтверждён.");
            new AlertDialog.Builder(this).setTitle("Добавить @"+name+"?")
                .setMessage("Ник @"+name+" подтверждён в Solana, и его владелец подписал эти ключи. Личность не проверена лично: при встрече сравните отпечаток.\n\n"+verified.optString("fingerprint"))
                .setNegativeButton("Отмена",null).setPositiveButton("Добавить",(d,w)->engine.pairFound(member,(done,failure)->{
                    if(isFinishing()||isDestroyed())return;
                    if(failure!=null){Toast.makeText(this,failure,Toast.LENGTH_LONG).show();return;}
                    String account=done.optString("account");
                    if(ContactNames.get(this,account).isEmpty())ContactNames.set(this,account,"@"+name);
                    renderedDialogs="";if(directoryDialog!=null)directoryDialog.dismiss();openChat(account);
                })).show();
        });
    }
    /** RFC-0028 link: https://paranoid.global/c/<server-id>/<nick> or paranoid://c/<server-id>/<nick>.
     * server-id = first 16 hex characters of the server's pinned TLS SPKI SHA-256. Never joins a server. */
    private String pendingLink;
    private void handleLink(Intent intent){
        if(intent==null||!Intent.ACTION_VIEW.equals(intent.getAction())||intent.getData()==null)return;
        android.net.Uri uri=intent.getData();java.util.List<String> parts=uri.getPathSegments();
        String server=null,nick=null;
        if("https".equals(uri.getScheme())&&"paranoid.global".equals(uri.getHost())&&parts.size()==3&&"c".equals(parts.get(0))){server=parts.get(1);nick=parts.get(2);}
        else if("paranoid".equals(uri.getScheme())&&"c".equals(uri.getHost())&&parts.size()==2){server=parts.get(0);nick=parts.get(1);}
        intent.setData(null);
        if(server==null||!server.matches("[0-9a-f]{16}")||nick==null||!nick.matches("[a-z][a-z0-9_]{2,23}")){Toast.makeText(this,"Ссылка ParanoID повреждена.",Toast.LENGTH_LONG).show();return;}
        pendingLink=server+"/"+nick;openPendingLink();
    }
    private void openPendingLink(){
        if(pendingLink==null||!resumed)return;
        if(broken)return;
        if(!hasIdentity||!active){if(latest.has("active")){pendingLink=null;Toast.makeText(this,"Сначала войдите через ник Solana, затем откройте ссылку снова.",Toast.LENGTH_LONG).show();}return;}
        if(!latest.has("server_id")&&!latest.optBoolean("connected"))return; // wait for server discovery
        String server=pendingLink.substring(0,16),nick=pendingLink.substring(17);pendingLink=null;
        if(!latest.has("server_id")){
            new AlertDialog.Builder(this).setTitle("Поиск недоступен").setMessage("Этот сервер не поддерживает поиск участников, поэтому ссылку на @"+nick+" открыть нельзя. Добавьте контакт через QR.").setPositiveButton("Закрыть",null).show();return;
        }
        if(!server.equals(latest.optString("server_id"))){
            new AlertDialog.Builder(this).setTitle("Этот сервер не подключён").setMessage("Ссылка на @"+nick+" ведёт на сервер "+server+", к которому этот телефон не подключён. ParanoID не подключается к серверам по ссылкам.").setPositiveButton("Закрыть",null).show();return;
        }
        engine.directorySearch(nick,null,(result,error)->{
            if(isFinishing()||isDestroyed())return;
            if(error!=null){Toast.makeText(this,error,Toast.LENGTH_LONG).show();return;}
            JSONArray members=result.optJSONArray("members");JSONObject exact=null;
            for(int n=0;members!=null&&n<members.length();n++){JSONObject m=members.optJSONObject(n);if(m!=null&&nick.equals(m.optString("name")))exact=m;}
            if(exact==null){Toast.makeText(this,"@"+nick+" не найден на этом сервере или скрыт из поиска.",Toast.LENGTH_LONG).show();return;}
            checkMember(exact);
        });
    }
    private void shareLink(){
        String name=latest.optString("directory_name"),server=latest.optString("server_id");
        if(name.isEmpty()||server.isEmpty()){Toast.makeText(this,"Ссылка появится после подключения к серверу.",Toast.LENGTH_LONG).show();return;}
        String link="https://paranoid.global/c/"+server+"/"+name;
        Intent intent=new Intent(Intent.ACTION_SEND);intent.setType("text/plain");intent.putExtra(Intent.EXTRA_TEXT,"Напишите мне в ParanoID: "+link);
        startActivity(Intent.createChooser(intent,"Поделиться моей ссылкой"));
    }
    private void pasteContact(){
        LinearLayout body=column();body.setPadding(dp(24),dp(8),dp(24),dp(4));
        body.addView(text("Вставьте контакт, которым собеседник поделился из раздела «Мой ID».",14,colors.muted,false));
        EditText field=new EditText(this);field.setTextSize(16);field.setHint("Контакт ParanoID");field.setContentDescription("Контакт ParanoID");field.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE|android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);field.setMinLines(3);field.setMaxLines(6);field.setFilters(new InputFilter[]{new InputFilter.LengthFilter(4096)});body.addView(field,full());
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle("Вставить контакт").setView(body).setNegativeButton("Отмена",null).setPositiveButton("Продолжить",null).create();
        dialog.setOnShowListener(v->dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(w->{String code=field.getText().toString().trim();if(code.isEmpty()){field.setError("Вставьте контакт собеседника");return;}dialog.dismiss();confirmContact(code);}));dialog.show();
    }
    private void confirmContact(String code){engine.previewContact(code,preview->{
        if(isFinishing()||isDestroyed())return;
        new AlertDialog.Builder(this).setTitle("Проверка контакта")
            .setMessage("Сравните полный отпечаток с экраном собеседника лично или по доверенному каналу. Один пересланный QR не доказывает личность.\n\n"+preview.optString("fingerprint"))
            .setNegativeButton("Отмена",null).setPositiveButton("Отпечаток совпадает",(d,w)->{engine.pair(code);show("contacts");}).show();
    });}
    private void contactDetails(){
        JSONObject selected=selectedDialog();if(selected==null)return;
        String account=selectedAccount;boolean blocked=selected.optBoolean("blocked");
        new AlertDialog.Builder(this).setTitle(ContactNames.title(this,account))
            .setMessage(DialogPolicy.trustLabel(selected)+"\n\n"+account+"\n\nСообщения защищены сквозным шифрованием. Проверка ключей при доставке не подтверждает, кому они принадлежат. Имя контакта хранится только на этом телефоне.\n\n✓ Сохранено сервером\n✓✓ Доставлено, не прочитано")
            .setPositiveButton("Переименовать",(d,w)->renameContact(account)).setNeutralButton("Проверить QR",(d,w)->addContact())
            .setNegativeButton(blocked?"Разблокировать контакт":"Заблокировать контакт",(d,w)->{
                if(blocked)engine.block(account,false);
                else new AlertDialog.Builder(this).setTitle("Заблокировать контакт?").setMessage("Новые сообщения и подтверждения доставки для этого контакта будут отключены. История останется на телефоне.")
                    .setNegativeButton("Отмена",null).setPositiveButton("Заблокировать",(confirm,which)->engine.block(account,true)).show();
            }).show();
    }
    /** Local-only display name (owner request 2026-09-12); never leaves the phone. */
    private void renameContact(String account){
        final EditText field=new EditText(this);field.setSingleLine(true);field.setHint("Имя контакта");field.setText(ContactNames.get(this,account));
        field.setFilters(new android.text.InputFilter[]{new android.text.InputFilter.LengthFilter(ContactNames.MAX_LENGTH)});field.setSelection(field.getText().length());
        FrameLayout wrap=new FrameLayout(this);wrap.setPadding(dp(20),dp(8),dp(20),0);wrap.addView(field,new FrameLayout.LayoutParams(-1,-2));
        new AlertDialog.Builder(this).setTitle("Имя контакта").setMessage("Отображается только на этом телефоне. Оставьте пустым, чтобы вернуть имя по умолчанию.").setView(wrap)
            .setNegativeButton("Отмена",null).setPositiveButton("Сохранить",(d,w)->{ContactNames.set(this,account,field.getText().toString());renderedDialogs="";renderedHistory="";changed(latest,lastStatus);show(page);}).show();
        field.requestFocus();
    }
    private void connectionDetails(){
        String info=lastStatus+"\n\nID и история сохраняются на этом телефоне. Статус сервера не показывает, находится ли собеседник в сети.";
        new AlertDialog.Builder(this).setTitle("Подключение").setMessage(info).setNegativeButton("Закрыть",null).setPositiveButton("Повторить подключение",(d,w)->engine.sync()).show();
    }
    private void copyPublic(String value,String confirmation){if(value.isEmpty())return;((ClipboardManager)getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText("Контакт ParanoID",value));Toast.makeText(this,confirmation,Toast.LENGTH_LONG).show();}
    @Override protected void onActivityResult(int request,int result,Intent data){super.onActivityResult(request,result,data);if(request!=45||result!=RESULT_OK||data==null)return;String raw=data.getStringExtra("public_qr");if(raw!=null&&raw.length()<=4096)confirmContact(raw);}
    @Override public void onRequestPermissionsResult(int request,String[] permissions,int[] results){
        super.onRequestPermissionsResult(request,permissions,results);
        if(request==MICROPHONE_PERMISSION){
            waitingForMicrophone=false;
            // The request may carry only CAMERA (video-call intent with the microphone already granted):
            // decide on the actual microphone grant, not on the array contents. A denied CAMERA never blocks the call.
            boolean microphone=checkSelfPermission(android.Manifest.permission.RECORD_AUDIO)==android.content.pm.PackageManager.PERMISSION_GRANTED;
            if(microphone){queueCallIntent();}
            else {
                cancelCallIntent();
                if(permissionAnswer&&engine.calls().snapshot().optString("call_id").equals(permissionCall))engine.calls().answer(false);
                Toast.makeText(this,"Для звонка нужен доступ к микрофону. Переписка доступна без него.",Toast.LENGTH_LONG).show();
            }
            return;
        }
        if(request==CAMERA_PERMISSION){
            waitingForCamera=false;
            boolean camera=results.length>0&&results[0]==android.content.pm.PackageManager.PERMISSION_GRANTED;
            if(camera&&engine.calls().active())engine.calls().video(true);
            else if(!camera)Toast.makeText(this,"Без доступа к камере звонок продолжается как аудио.",Toast.LENGTH_LONG).show();
            return;
        }
        if(request==BLUETOOTH_PERMISSION)return; // Optional: the call proceeds without Bluetooth routing.
        if(request==BackgroundConnectionService.NOTIFICATION_PERMISSION) {
            if(results.length>0&&results[0]==android.content.pm.PackageManager.PERMISSION_GRANTED){BackgroundConnectionService.requestStart(this);requestBatteryException();}
            else Toast.makeText(this,"Фоновое подключение выключено: разрешите уведомления, чтобы видеть его статус.",Toast.LENGTH_LONG).show();
        }
    }

    private void renderLists()throws Exception{
        JSONArray all=latest.optJSONArray("dialogs");
        // The call log changes no message, so its revision has to be part of the signature or a new
        // call row would wait for an unrelated message before it appeared (CallLog.revision).
        String signature=(all==null?"[]":all.toString())+"|"+CallLog.revision(this);
        if(signature.equals(renderedDialogs))return;renderedDialogs=signature;contactList.removeAllViews();dialogList.removeAllViews();
        if(all==null||all.length()==0){
            empty(dialogList,"Первый разговор начинается здесь","Сообщения собеседников появятся здесь автоматически. Чтобы написать первым, добавьте контакт.",this::addContact);
            empty(contactList,"Пока нет контактов","Контакт можно добавить по QR или вставить из сообщения собеседника.",this::addContact);return;
        }
        for(int n=0;n<all.length();n++){
            JSONObject dialog=all.getJSONObject(n);String account=dialog.getString("account");JSONArray messages=dialog.optJSONArray("messages");
            JSONObject last=messages!=null&&messages.length()>0?messages.getJSONObject(messages.length()-1):null;
            String preview=last==null?"Начать переписку":MessagePresentation.preview(last.optString("text"));
            if(last!=null&&last.optString("author").equals(dialog.optString("own")))preview="Вы: "+preview;
            // A call that happened after the newest message is what the row should say.
            JSONArray calls=CallLog.records(this,account);
            JSONObject lastCall=calls.length()>0?calls.optJSONObject(calls.length()-1):null;
            boolean callPreview=lastCall!=null&&lastCall.optString("after_message_id","").equals(last==null?"":last.optString("id"));
            if(callPreview)
                preview=MessagePresentation.callLine(lastCall.optString("kind"),lastCall.optBoolean("video"),lastCall.optLong("duration_seconds"));
            conversationRow(dialogList,dialog,preview,last,callPreview);
            conversationRow(contactList,dialog,DialogPolicy.trustLabel(dialog),null,false);
        }
    }
    private void conversationRow(LinearLayout container,JSONObject dialog,String preview,JSONObject last,boolean callPreview){
        String account=dialog.optString("account");LinearLayout row=row();row.setGravity(Gravity.CENTER_VERTICAL);row.setPadding(dp(12),dp(14),dp(12),dp(14));row.setMinimumHeight(dp(88));row.setBackground(ripple(colors.canvas,18));row.setOnClickListener(v->openChat(account));row.setFocusable(true);
        TextView avatar=text(account.substring(0,Math.min(2,account.length())).toUpperCase(java.util.Locale.ROOT),17,colors.actionText,true);avatar.setGravity(Gravity.CENTER);avatar.setBackground(shape(colors.actionSoft,28));avatar.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);row.addView(avatar,box(52,52));
        LinearLayout lines=column();LinearLayout.LayoutParams lineParams=new LinearLayout.LayoutParams(0,-2,1);lineParams.setMargins(dp(12),0,dp(8),0);row.addView(lines,lineParams);
        TextView title=text(ContactNames.title(this,account),16,colors.text,true);title.setMaxLines(1);title.setEllipsize(TextUtils.TruncateAt.END);lines.addView(title);
        TextView snippet=text(preview,14,colors.muted,false);snippet.setMaxLines(2);snippet.setEllipsize(TextUtils.TruncateAt.END);LinearLayout.LayoutParams snippetParams=full();snippetParams.topMargin=dp(4);lines.addView(snippet,snippetParams);
        LinearLayout side=column();side.setGravity(Gravity.END);row.addView(side,new LinearLayout.LayoutParams(-2,-2));
        String when=last==null?"":MessagePresentation.listTime(last.optLong("local_ms",0),System.currentTimeMillis(),callPreview);
        if(!when.isEmpty()){TextView stamp=text(when,12,colors.muted,false);stamp.setGravity(Gravity.END);side.addView(stamp);}
        String marker=dialog.optBoolean("blocked")?"Блок":dialog.optString("trust").equals("out_of_band_verified")?"Проверен":"";
        if(!marker.isEmpty()){TextView badge=text(marker,11,colors.muted,false);badge.setGravity(Gravity.END);side.addView(badge);}
        else if(last!=null&&last.optString("author").equals(dialog.optString("own"))){side.addView(new ReceiptMark(this,last,colors.muted),box(24,18));}
        container.addView(row,full());
    }
    private void empty(LinearLayout container,String title,String body,Runnable action){
        LinearLayout card=column();card.setPadding(dp(20),dp(32),dp(20),dp(24));card.setBackground(shape(colors.surface,24));LinearLayout.LayoutParams params=full();params.setMargins(dp(4),dp(12),dp(4),dp(12));container.addView(card,params);
        ImageView icon=new ImageView(this);icon.setImageDrawable(new Symbol("chat",colors.action));icon.setPadding(dp(14),dp(14),dp(14),dp(14));icon.setBackground(shape(colors.actionSoft,20));icon.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);card.addView(icon,box(64,64));space(card,20);
        card.addView(text(title,23,colors.text,true));space(card,12);card.addView(text(body,15,colors.muted,false));space(card,24);card.addView(action("Добавить контакт",action),full());
    }
    private void renderHistory(boolean force){
        JSONObject dialog=selectedDialog();if(dialog==null)return;
        boolean blocked=dialog.optBoolean("blocked");chatTrust.setText(DialogPolicy.trustLabel(dialog)+(blocked?" · Заблокирован":" · Подробнее"));
        JSONArray messages=dialog.optJSONArray("messages");
        JSONArray calls=CallLog.records(this,selectedAccount);
        String signature=selectedAccount+":"+(messages==null?"[]":messages.toString())+"|"+CallLog.revision(this)+"|"+ReceiptHint.isPending(this);
        if(!force&&signature.equals(renderedHistory))return;renderedHistory=signature;
        boolean nearBottom=force||history.getHeight()-messageScroll.getHeight()-messageScroll.getScrollY()<dp(100);
        int oldScroll=messageScroll.getScrollY();history.removeAllViews();
        JSONArray rows=MessagePresentation.chatRows(messages,calls);
        long previousDay=0,nowMs=System.currentTimeMillis();
        if(rows.length()==0){TextView start=text("Начните переписку. Сообщения защищены сквозным шифрованием.",14,colors.muted,false);start.setGravity(Gravity.CENTER);start.setPadding(dp(24),dp(32),dp(24),dp(32));history.addView(start,full());}
        else for(int n=0;n<rows.length();n++){
            JSONObject entry=rows.optJSONObject(n);if(entry==null)continue;
            if(entry.optString("type").equals("call")){callRow(entry.optJSONObject("value"));continue;}
            JSONObject message=entry.optJSONObject("value");if(message==null)continue;
            // Only a message carries a time, so only a message opens a day; an entry written by a
            // build that kept none opens nothing and is shown without one (REQ-CLIENT-004).
            long when=message.optLong("local_ms",0);
            if(MessagePresentation.startsNewDay(when,previousDay)){
                String day=MessagePresentation.daySeparator(when,nowMs);
                if(!day.isEmpty()){
                    TextView pill=text(day,12,colors.muted,false);pill.setGravity(Gravity.CENTER);
                    pill.setPadding(dp(10),dp(3),dp(10),dp(3));pill.setBackground(shape(colors.surface,12));
                    LinearLayout dayRow=row();dayRow.setGravity(Gravity.CENTER);
                    LinearLayout.LayoutParams dayParams=full();dayParams.topMargin=dp(10);
                    history.addView(dayRow,dayParams);dayRow.addView(pill,new LinearLayout.LayoutParams(-2,-2));
                }
            }
            if(when>0)previousDay=when;
            boolean mine=message.optString("author").equals(dialog.optString("own"));
            LinearLayout row=row();row.setGravity(mine?Gravity.END:Gravity.START);LinearLayout.LayoutParams rowParams=full();rowParams.topMargin=dp(6);history.addView(row,rowParams);
            LinearLayout bubble=column();bubble.setPadding(dp(14),dp(10),dp(14),dp(8));bubble.setBackground(bubble(mine));
            LinearLayout.LayoutParams bubbleParams=new LinearLayout.LayoutParams(-2,-2);if(mine)bubbleParams.leftMargin=dp(40);else bubbleParams.rightMargin=dp(40);row.addView(bubble,bubbleParams);
            TextView body=text(message.optString("text"),16,colors.text,false);body.setTextIsSelectable(true);body.setMaxWidth(Math.min(dp(440),Math.max(dp(160),getResources().getDisplayMetrics().widthPixels-dp(92))));bubble.addView(body);
            String stamp=MessagePresentation.time(when);
            if(mine){
                LinearLayout footer=row();footer.setGravity(Gravity.END|Gravity.CENTER_VERTICAL);footer.setPadding(0,dp(5),0,0);
                if(!stamp.isEmpty()){TextView at=text(stamp,11,colors.muted,false);at.setPadding(0,0,dp(4),0);footer.addView(at);}
                footer.addView(new ReceiptMark(this,message,colors.muted),box(24,18));
                bubble.addView(footer,full());
            } else if(!stamp.isEmpty()){
                TextView at=text(stamp,11,colors.muted,false);at.setPadding(0,dp(5),0,0);bubble.addView(at,full());
            }
        }
        if(ReceiptHint.shouldShow(this,dialog))receiptHintCard();
        messageScroll.post(()->{if(nearBottom)messageScroll.scrollTo(0,history.getHeight());else messageScroll.scrollTo(0,oldScroll);});
    }
    private void receiptHintCard(){
        LinearLayout card=column();card.setPadding(dp(14),dp(12),dp(14),dp(12));card.setBackground(shape(colors.surface,18));
        card.addView(text("Две отметки — сообщение доставлено на телефон собеседника. Прочитал ли он его, ParanoID не показывает.",13,colors.muted,false),full());
        Button dismiss=secondary("Понятно",()->{ReceiptHint.dismiss(this);renderHistory(false);});
        card.addView(dismiss);
        LinearLayout.LayoutParams params=full();params.topMargin=dp(10);history.addView(card,params);
    }

    /**
     * What one finished call left in the conversation. It is a line and not a bubble because nobody
     * wrote it: the core stores no call history and the peer keeps its own account of the same call
     * (CallLog). A missed call is the one outcome that asks something of the reader, so it is the
     * one that carries «Перезвонить».
     */
    private void callRow(JSONObject call){
        if(call==null)return;
        String kind=call.optString("kind");
        boolean missed=MessagePresentation.callMissed(kind);
        LinearLayout row=row();row.setGravity(Gravity.CENTER);LinearLayout.LayoutParams rowParams=full();rowParams.topMargin=dp(6);history.addView(row,rowParams);
        LinearLayout pill=row();pill.setGravity(Gravity.CENTER_VERTICAL);pill.setPadding(dp(14),dp(8),dp(14),dp(8));pill.setBackground(shape(colors.surface,18));
        row.addView(pill,new LinearLayout.LayoutParams(-2,-2));
        TextView line=text(MessagePresentation.callLine(kind,call.optBoolean("video"),call.optLong("duration_seconds")),13,missed?colors.danger:colors.muted,false);
        pill.addView(line);
        if(missed){
            Button back=secondary(MessagePresentation.callBack(),()->requestCall(false));
            back.setPadding(dp(10),dp(4),dp(4),dp(4));back.setMinHeight(0);back.setMinimumHeight(0);
            pill.addView(back);
        }
    }
    private Drawable bubble(boolean outgoing){GradientDrawable shape=shape(outgoing?colors.outgoing:colors.incoming,17);float r=dp(17),small=dp(6);shape.setCornerRadii(outgoing?new float[]{r,r,r,r,small,small,r,r}:new float[]{r,r,r,r,r,r,small,small});return shape;}

    @Override public void changed(JSONObject view,String message){
        if(isFinishing()||isDestroyed())return;
        try{
            boolean hadProfile=hasIdentity||hasBlockchainNick||nicknameReadFailed;
            latest=view;broken=view.optBoolean("broken");hasIdentity=view.optBoolean("identity");active=view.optBoolean("active");creating=false;identityLogin=view.optBoolean("identity_login");
            String solNick=view.optString("solana_nick","");
            hasBlockchainNick="verified".equals(view.optString("nickname_state"))&&!solNick.isEmpty();
            String nicknameState=view.optString("nickname_state","loading");
            nicknameReadFailed="unavailable".equals(nicknameState);
            boolean profileKnown=!"loading".equals(nicknameState)&&!nicknameReadFailed;
            loginHint.setVisibility(hasIdentity&&identityLogin&&!active&&!broken?View.VISIBLE:View.GONE);
            // New install: go straight to the one-step-per-screen onboarding, once per process.
            if(!hasIdentity&&!hasBlockchainNick&&profileKnown&&!broken&&!view.optBoolean("unsupported_snapshot")&&resumed&&!onboardingOpened)openOnboarding();
            if(!hasIdentity&&(hasBlockchainNick||nicknameReadFailed))page="identity";
            background.setText(view.optBoolean("background_enabled")?"Отключить фоновое подключение":"Включить фоновое подключение");background.setEnabled(hasIdentity&&!broken);
            boolean backgroundEnabled=view.optBoolean("background_enabled");
            boolean backgroundPrompted=getSharedPreferences(UI_PREFS,MODE_PRIVATE).getBoolean(BACKGROUND_PROMPT_KEY,false);
            backgroundHint.setVisibility(hasIdentity&&!broken&&!backgroundEnabled&&backgroundPrompted?View.VISIBLE:View.GONE);
            if(hasIdentity&&!broken&&!backgroundEnabled&&!backgroundPrompted&&resumed)offerBackground();
            lastStatus=view.optBoolean("unsupported_snapshot")?"Сохранённые данные относятся к предыдущей тестовой версии. Эта сборка предназначена для новой установки. Данные не изменены.":broken?"Локальные данные недоступны. Ключи и история не сброшены. Не удаляйте приложение.":message;
            String connection=broken?"Данные недоступны · подробнее":!hasIdentity?"Закрытая альфа · тестовые сообщения":!active?(identityLogin?"Нужен вход через ник Solana":"Регистрируем ID · ключи сохранены"):view.optBoolean("connected")?"Сервер подключён":message.startsWith("Синхронизация завершена")?"Сообщения обновлены":message.startsWith("Сообщение сохранено")?"Сообщение в очереди":message.equals("Готово")||message.startsWith("Готово.")?"Подключаемся к серверу…":"Подключение · подробнее";
            if(view.optLong("rejected_count")>0)connection="Есть непринятые сообщения · подробнее";
            status.setText(connection);status.setTextColor(broken?colors.danger:colors.muted);
            // Nickname and server membership are independent. Loading/failure is not absence.
            nickView.setText(hasBlockchainNick?"@"+solNick:"");
            nickView.setVisibility(hasBlockchainNick?View.VISIBLE:View.GONE);
            identityStateBlock.setVisibility(hasBlockchainNick&&active&&!broken?View.GONE:View.VISIBLE);
            identityStateAction.setVisibility(View.VISIBLE);
            identityStateAction.setEnabled(true);
            identityStateAction.setOnClickListener(v->openOnboarding());
            if(hasBlockchainNick){
                identityStateTitle.setText("Сервер не подключён");
                identityStateBody.setText("Ник сохранён. Подключите сервер, чтобы переписываться.");
                identityStateAction.setText("Подключить сервер");
                if(broken){
                    identityStateBody.setText("Ник сохранён. Данные переписки недоступны; они не удалены. Не переустанавливайте приложение.");
                    identityStateAction.setVisibility(View.GONE);
                }
            }else if("loading".equals(nicknameState)){
                identityStateTitle.setText("Проверяем сохранённый ник…");
                identityStateBody.setText("");identityStateAction.setVisibility(View.GONE);
            }else if("unavailable".equals(nicknameState)){
                identityStateTitle.setText("Ник пока недоступен");
                identityStateBody.setText("Не удалось прочитать сохранённую учётную запись. Данные не удалены. Не переустанавливайте приложение.");
                identityStateAction.setText("Повторить");
                identityStateAction.setOnClickListener(v->engine.refreshNicknameProfile());
            }else if("pending".equals(nicknameState)){
                identityStateTitle.setText("Регистрация ещё не подтверждена");
                identityStateBody.setText("Проверьте результат регистрации. Повторно создавать аккаунт не нужно.");
                identityStateAction.setText("Проверить ник");
            }else{
                identityStateTitle.setText("Создайте или восстановите ник");
                identityStateBody.setText("Ник — ваш аккаунт. Он не зависит от подключения к серверу.");
                identityStateAction.setText("Продолжить");
            }
            // Technical key/QR remnants stay hidden; no contact authority changes here.
            myId.setVisibility(View.GONE);qr.setVisibility(View.GONE);
            share.setVisibility(View.GONE);copy.setVisibility(View.GONE);fingerprint.setVisibility(View.GONE);
            myId.setText("");
            // QR removed from UI; keep displayedQr for share/copy logic that may still reference it
            JSONObject contact=view.optJSONObject("contact");
            if(active&&contact!=null){String raw=contact.toString();displayedQr=raw;}fingerprint.setText("");
            if(!draft.getText().toString().equals(drafts.text(selectedAccount)))restoreDraft();
            directoryBlock.setVisibility(active&&view.optBoolean("directory")?View.VISIBLE:View.GONE);
            renderLists();renderHistory(false);
            openPendingLink();
            if(hadProfile!=(hasIdentity||hasBlockchainNick||nicknameReadFailed)||(!hasIdentity&&(hasBlockchainNick||nicknameReadFailed)))show(page);else buttons();
            if(broken)show(page);
            autoCheckUpdates();
        }catch(Exception ignored){lastStatus="Не удалось обновить экран. Данные сохранены.";status.setText("Ошибка отображения · подробнее");}
    }

    @Override public void onResume(){super.onResume();resumed=true;engine.listen(this);engine.listenCalls(callListener);handler.removeCallbacks(poll);handler.post(poll);if(pendingCallIntent)handler.post(this::completeCallIntent);
        if(videoPausedByBackground){videoPausedByBackground=false;if(engine.calls().active()&&checkSelfPermission(android.Manifest.permission.CAMERA)==android.content.pm.PackageManager.PERMISSION_GRANTED)engine.calls().video(true);}}
    @Override public void onPause(){resumed=false;if(!waitingForMicrophone)cancelCallIntent();handler.removeCallbacks(poll);
        // Camera never runs while the app is not visible; audio continues. Permission dialogs keep the camera.
        if(!waitingForCamera&&engine.calls().active()&&engine.calls().snapshot().optBoolean("local_video")){videoPausedByBackground=true;engine.calls().video(false);}
        engine.unlisten(this);engine.unlistenCalls(callListener);super.onPause();}
    @Override public void onDestroy(){if(callDialog!=null){callDialog.dismiss();callDialog=null;}super.onDestroy();}
    private void attachRenderers(){
        WebRtcAudioEngine media=engine.media();if(media==null||renderersInitialized)return;
        org.webrtc.EglBase.Context egl=media.eglContext();if(egl==null)return;
        try{
            remoteRenderer.init(egl,null);remoteRenderer.setScalingType(org.webrtc.RendererCommon.ScalingType.SCALE_ASPECT_FIT);remoteRenderer.setEnableHardwareScaler(true);
            localRenderer.init(egl,null);localRenderer.setScalingType(org.webrtc.RendererCommon.ScalingType.SCALE_ASPECT_FILL);localRenderer.setMirror(true);localRenderer.setZOrderMediaOverlay(true);localRenderer.setEnableHardwareScaler(true);
            renderersInitialized=true;media.setRemoteSink(remoteRenderer);media.setLocalSink(localRenderer);
        }catch(RuntimeException failure){renderersInitialized=false;}
    }
    private void releaseRenderers(){
        if(!renderersInitialized)return;renderersInitialized=false;
        WebRtcAudioEngine media=engine.media();if(media!=null){media.setRemoteSink(null);media.setLocalSink(null);}
        try{remoteRenderer.release();}catch(RuntimeException ignored){}
        try{localRenderer.release();}catch(RuntimeException ignored){}
    }
    @Override public void onBackPressed(){if(page.equals("chat")){show("dialogs");}else if(!page.equals("dialogs")){show("dialogs");}else super.onBackPressed();}
    @Override public Object onRetainNonConfigurationInstance(){return new Retained(drafts,page,selectedAccount);}
    private static final class Retained{final MessagePresentation.Drafts drafts;final String page,account;Retained(MessagePresentation.Drafts d,String p,String a){drafts=d;page=p;account=a;}}
    private void hideKeyboard(){if(draft!=null)((InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(draft.getWindowToken(),0);}

    private int dp(float value){return Math.round(value*getResources().getDisplayMetrics().density);}
    private LinearLayout column(){LinearLayout v=new LinearLayout(this);v.setOrientation(LinearLayout.VERTICAL);return v;}
    private LinearLayout row(){LinearLayout v=new LinearLayout(this);v.setOrientation(LinearLayout.HORIZONTAL);v.setBaselineAligned(false);return v;}
    private LinearLayout.LayoutParams box(int width,int height){return new LinearLayout.LayoutParams(dp(width),dp(height));}
    private LinearLayout.LayoutParams full(){return new LinearLayout.LayoutParams(-1,-2);}
    private void space(LinearLayout parent,int height){parent.addView(new View(this),box(1,height));}
    private TextView text(String value,int size,int color,boolean bold){TextView v=new TextView(this);v.setText(value);v.setTextSize(size);v.setTextColor(color);v.setFontFeatureSettings("kern");v.setIncludeFontPadding(false);v.setLineSpacing(dp(2),1f);if(bold)v.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));return v;}
    private GradientDrawable shape(int color,int radius){GradientDrawable v=new GradientDrawable();v.setColor(color);v.setCornerRadius(dp(radius));return v;}
    private Drawable ripple(int color,int radius){return new RippleDrawable(ColorStateList.valueOf(colors.dark?0x338e9cff:0x225557e9),shape(color,radius),shape(0xffffffff,radius));}
    private Button action(String label,Runnable run){Button v=secondary(label,run);v.setTextColor(colors.onAction);v.setBackground(ripple(colors.action,24));return v;}
    private Button secondary(String label,Runnable run){Button v=new Button(this);v.setAllCaps(false);v.setText(label);v.setTextSize(15);v.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));v.setTextColor(colors.action);v.setMinHeight(dp(48));v.setMinimumHeight(dp(48));v.setMinimumWidth(0);v.setMinWidth(0);v.setPadding(dp(16),dp(12),dp(16),dp(12));v.setBackground(ripple(colors.raised,24));v.setStateListAnimator(null);v.setOnClickListener(w->run.run());return v;}
    private ImageButton iconButton(String name,String label,Runnable run){ImageButton v=new ImageButton(this);v.setImageDrawable(new Symbol(name,colors.action));v.setContentDescription(label);v.setPadding(dp(12),dp(12),dp(12),dp(12));v.setBackground(ripple(colors.canvas,24));v.setOnClickListener(w->run.run());return v;}
    private void addScrollablePage(LinearLayout content){ScrollView scroll=new ScrollView(this);scroll.setFillViewport(true);scroll.setClipToPadding(false);scroll.addView(content,new ScrollView.LayoutParams(-1,-2));pages.addView(scroll,new FrameLayout.LayoutParams(-1,-1));}

    /** sRGB conversions of the supplied prototype's semantic OKLCH tokens. */
    private static final class Palette{
        final boolean dark;final int canvas,surface,raised,text,muted,border,action,actionText,onAction,actionSoft,danger,incoming,outgoing;
        Palette(boolean dark){this.dark=dark;canvas=dark?0xff070c17:0xfff5f8fd;surface=dark?0xff101726:0xffffffff;raised=dark?0xff182336:0xffebf0f8;text=dark?0xfff0f4f9:0xff0e192c;muted=dark?0xffa9b5c8:0xff465061;border=dark?0xff2c384d:0xffd4dbe7;action=dark?0xff8e9cff:0xff5557e9;actionText=dark?0xff8e9cff:0xff433cd2;onAction=dark?0xff070c17:0xffffffff;actionSoft=dark?0xff222650:0xffdae2ff;danger=dark?0xfffd7273:0xffc72536;incoming=dark?0xff1b2739:0xffe4eaf4;outgoing=dark?0xff323876:0xffc9d4ff;}
    }
    /** Consistent 24dp outline controls; no emoji or fabricated product imagery. */
    private final class Symbol extends Drawable{
        private final String name;private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
        Symbol(String name,int color){this.name=name;paint.setColor(color);paint.setStyle(Paint.Style.STROKE);paint.setStrokeWidth(1.8f);paint.setStrokeCap(Paint.Cap.ROUND);paint.setStrokeJoin(Paint.Join.ROUND);setBounds(0,0,dp(24),dp(24));}
        @Override public int getIntrinsicWidth(){return dp(24);}@Override public int getIntrinsicHeight(){return dp(24);}
        @Override public void draw(Canvas c){c.save();c.translate(getBounds().left,getBounds().top);c.scale(getBounds().width()/24f,getBounds().height()/24f);
            Path p=new Path();
            if(name.equals("chat")){c.drawRoundRect(3,3,21,18,5,5,paint);p.moveTo(8,18);p.lineTo(4,22);p.lineTo(4,16);c.drawPath(p,paint);}
            else if(name.equals("contacts")){c.drawCircle(9,7,3,paint);c.drawArc(3,12,15,24,180,180,false,paint);c.drawArc(14,4,21,11,-90,180,false,paint);c.drawArc(14,12,23,22,-90,90,false,paint);}
            else if(name.equals("back")){p.moveTo(15,4);p.lineTo(7,12);p.lineTo(15,20);c.drawPath(p,paint);}
            else if(name.equals("send")){p.moveTo(4,11);p.lineTo(21,3);p.lineTo(13,21);p.lineTo(10,14);p.lineTo(4,11);p.moveTo(10,14);p.lineTo(21,3);c.drawPath(p,paint);}
            else if(name.equals("compose")){p.moveTo(15,4);p.lineTo(20,9);p.lineTo(10,19);p.lineTo(4,20);p.lineTo(5,14);p.close();c.drawPath(p,paint);c.drawLine(13,6,18,11,paint);}
            else if(name.equals("more")){c.drawCircle(12,5,1,paint);c.drawCircle(12,12,1,paint);c.drawCircle(12,19,1,paint);}
            else if(name.equals("video")){c.drawRoundRect(3,6,15,18,3,3,paint);p.moveTo(15,10);p.lineTo(21,7);p.lineTo(21,17);p.lineTo(15,14);c.drawPath(p,paint);}
            else if(name.equals("phone")){p.moveTo(5,3);p.lineTo(9,3);p.lineTo(11,8);p.lineTo(8,10);p.quadTo(11,16,15,16);p.lineTo(17,13);p.lineTo(22,15);p.lineTo(22,19);p.quadTo(13,25,4,11);p.quadTo(2,5,5,3);c.drawPath(p,paint);}
            else{c.drawCircle(12,9,3,paint);c.drawArc(6,14,18,25,180,180,false,paint);c.drawArc(2,2,22,22,30,280,false,paint);c.drawCircle(21,7,1.3f,paint);}
            c.restore();}
        @Override public void setAlpha(int alpha){paint.setAlpha(alpha);}@Override public void setColorFilter(ColorFilter filter){paint.setColorFilter(filter);}@Override public int getOpacity(){return PixelFormat.TRANSLUCENT;}
    }
}
