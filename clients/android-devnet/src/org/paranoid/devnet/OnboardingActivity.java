package org.paranoid.devnet;

import android.app.*;
import android.content.*;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.text.InputFilter;
import android.text.InputType;
import android.util.Base64;
import android.view.*;
import android.view.inputmethod.EditorInfo;
import android.widget.*;
import java.io.IOException;
import java.security.SecureRandom;
import java.util.*;
import java.util.concurrent.*;
import org.json.*;

/**
 * First-run flow, one decision per screen (RFC-0027 private Devnet test):
 * start (create / restore nick) → words → nick → registration → server → done.
 * The step is derived from durable Devnet state on every open, so a killed app
 * resumes where it stopped. Screenshots are allowed everywhere except while the
 * 24 recovery words are shown or typed.
 */
public final class OnboardingActivity extends Activity {
    private static final ExecutorService OWNER=Executors.newSingleThreadExecutor();
    private static DevnetStore store;
    private final UiGeneration generation=new UiGeneration();
    private LinearLayout page;
    private int accent,muted,text,surface;
    private interface Step { String run(DevnetStore s,long ticket)throws Exception; }

    @Override public void onCreate(Bundle b){
        super.onCreate(b);
        boolean night=(getResources().getConfiguration().uiMode&android.content.res.Configuration.UI_MODE_NIGHT_MASK)==android.content.res.Configuration.UI_MODE_NIGHT_YES;
        text=night?0xffeceff4:0xff111827;muted=night?0xff9aa4b2:0xff5b6472;accent=0xff2563eb;surface=night?0xff1f2530:0xfff1f4f9;
        getWindow().setStatusBarColor(night?0xff12161d:0xffffffff);
        ScrollView scroll=new ScrollView(this);scroll.setFillViewport(true);scroll.setBackgroundColor(night?0xff12161d:0xffffffff);
        page=new LinearLayout(this);page.setOrientation(LinearLayout.VERTICAL);page.setPadding(dp(24),dp(48),dp(24),dp(24));
        scroll.addView(page);setContentView(scroll);
        resume();
    }
    @Override public void onDestroy(){generation.next();super.onDestroy();}
    @Override public void onBackPressed(){moveTaskToBack(true);}

    // ---------- state machine ----------
    private void resume(){
        busy("Загружаем…");
        run((s,t)->{
            JSONObject st=s.load();
            if(st==null){post(t,this::start);return null;}
            if(!st.optBoolean("backup")){String w=SolanaBridge.run(new JSONObject().put("op","export_mnemonic").put("entropy",st.getString("entropy"))).getString("mnemonic");post(t,()->words(w));return null;}
            if(!st.optBoolean("verified")&&st.optString("name").isEmpty()){post(t,()->nick(null));return null;}
            if(!st.optBoolean("verified")){post(t,()->registering(st.optString("name")));return null;}
            String nick=st.getString("name");post(t,()->server(nick));return null;
        });
    }

    private void start(){
        clear();secure(false);
        title("ParanoID");
        body("Ваш ник — это ваш аккаунт. Он хранится в сети Solana (тестовая сеть Devnet), ключ остаётся только на этом телефоне. Телефон, email и пароль не нужны.");
        gap(32);
        primary("Создать ник",this::createKey);
        gap(12);
        secondary("У меня уже есть ник",this::restore);
    }

    private void createKey(){
        busy("Создаём ключ…");
        run((s,t)->{
            if(s.load()==null){
                byte[] e=new byte[16];new SecureRandom().nextBytes(e);/* 12 words (RFC-0026 rev. 2026-09-29) */String entropy=Base64.encodeToString(e,Base64.NO_WRAP);Arrays.fill(e,(byte)0);
                s.save(new JSONObject().put("entropy",entropy).put("program",DevnetRpc.PROGRAM).put("genesis",DevnetRpc.GENESIS).put("backup",false).put("attempts",new JSONArray()));
            }
            post(t,this::resume);return null;
        });
    }

    private void words(String mnemonic){
        clear();secure(true);
        step("Шаг 1 из 3");title("Запишите 12 слов");
        body("Только по ним можно вернуть ник на новом телефоне. Никому их не показывайте. Скриншот этого экрана запрещён.");
        gap(16);
        String[] w=mnemonic.split(" ");StringBuilder out=new StringBuilder();
        for(int i=0;i<w.length;i++)out.append(String.format(Locale.ROOT,"%2d. %-10s%s",i+1,w[i],i%2==1?"\n":"  "));
        TextView list=label(out.toString(),17,text,false);list.setTypeface(Typeface.MONOSPACE);list.setPadding(dp(16),dp(16),dp(16),dp(16));list.setBackground(round(surface,16));list.setSaveEnabled(false);page.addView(list,full());
        gap(24);
        primary("Я записал слова",()->new AlertDialog.Builder(this).setTitle("Точно записали?").setMessage("Без этих слов ник восстановить невозможно.")
            .setPositiveButton("Да",(d,x)->{list.setText("");busy("Сохраняем…");run((s,t)->{JSONObject st=RegistrationFlow.required(s);st.put("backup",true);s.save(st);post(t,this::resume);return null;});})
            .setNegativeButton("Нет",null).show());
    }

    private void nick(String error){
        clear();secure(false);
        step("Шаг 2 из 3");title("Придумайте ник");
        body("Латиница, цифры и _, от 3 до 24 символов, начинается с буквы. Сменить ник потом нельзя.");
        gap(20);
        EditText in=new EditText(this);in.setHint("например, sergey");in.setSingleLine(true);in.setTextSize(20);
        in.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS|InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD);
        in.setFilters(new InputFilter[]{new InputFilter.LengthFilter(32)});
        page.addView(in,full());
        if(error!=null){gap(8);page.addView(label(error,14,0xffdc2626,false));}
        gap(24);
        primary("Занять ник",()->{String n=in.getText().toString().trim().toLowerCase(Locale.ROOT).replaceAll("[\\s\\u00a0\\u200b-\\u200d\\ufeff]","");
            if(!n.matches("[a-z][a-z0-9_]{2,23}")){nick("Такой ник не подходит: только a-z, 0-9 и _, от 3 до 24 символов, первая — буква.");return;}
            registering(n);});
    }

    /** Funds with the Devnet faucet once if needed, registers, and waits for finalization. */
    private void registering(String n){
        clear();secure(false);
        step("Шаг 3 из 3");title("Регистрируем @"+n);
        TextView progress=label("Подключаемся к Solana…",16,muted,false);page.addView(progress);
        ProgressBar bar=new ProgressBar(this);gap(24);page.addView(bar);
        run((s,t)->{
            DevnetRpc rpc=new DevnetRpc();
            JSONObject st=RegistrationFlow.required(s);
            String owner=SolanaBridge.run(new JSONObject().put("op","identity").put("entropy",st.getString("entropy"))).getString("owner");
            if(st.optString("name").isEmpty()||!st.optBoolean("verified")){
                // Already registered in an earlier run? check() also discovers the on-chain nick.
                RegistrationFlow.check(s,rpc);st=s.load();
            }
            if(!st.optBoolean("verified")){
                say(t,progress,"Записываем ник в блокчейн…");
                // RFC-0026 rev. 2026-09-30: the ParanoID server pays for the nick. Own test SOL
                // (e.g. a wallet funded earlier) is used only if the sponsor is unavailable.
                try{RegistrationFlow.registerSponsored(s,rpc,sponsor(),n);}
                catch(org.paranoid.text.SyncCycle.Rejected refused){
                    if(refused.code.equals("sponsor_used"))throw new IOException("name_conflict_or_partial_record");
                    if(balance(rpc,owner)<5_000_000L)throw new IOException("insufficient_devnet_sol");
                    RegistrationFlow.register(s,rpc,n);
                }
                for(int i=0;i<40&&!s.load().optBoolean("verified");i++){
                    say(t,progress,"Ждём подтверждения сети… "+(i*3)+" с");Thread.sleep(3000);RegistrationFlow.check(s,rpc);
                }
                if(!s.load().optBoolean("verified"))throw new IOException("registration_pending");
            }
            post(t,this::resume);return null;
        },(t,code)->{
            if("name_conflict_or_partial_record".equals(code)||"identity_already_registered".equals(code)){nick("Ник @"+n+" уже занят. Выберите другой.");return;}
            if("insufficient_devnet_sol".equals(code)){noFunds(n);return;}
            String m=DevnetWork.run(()->{throw new IOException(code);});
            failure(m.contains("(IOException)")?"Регистрация не завершена ("+code+"). Нажмите «Повторить»: уже отправленная транзакция не дублируется.":m,()->registering(n));
        });
    }

    private void noFunds(String n){
        busy("Проверяем баланс…");
        run((s,t)->{
            String a=SolanaBridge.run(new JSONObject().put("op","identity").put("entropy",RegistrationFlow.required(s).getString("entropy"))).getString("owner");
            String bal;try{bal=java.math.BigDecimal.valueOf(balance(new DevnetRpc(),a),9).stripTrailingZeros().toPlainString();}catch(Exception e){bal="неизвестен";}
            String shown=bal;post(t,()->noFundsScreen(n,a,shown));return null;
        });
    }
    private void noFundsScreen(String n,String address,String bal){
        clear();secure(false);
        title("Нужны тестовые SOL");
        body("Сервер ParanoID сейчас не смог оплатить запись ника (лимит или пустой кошелёк). Можно подождать и нажать «Продолжить» или пополнить свой адрес: нужно ~0,005 тестовых SOL, это не настоящие деньги.\n\n1. Нажмите «Скопировать адрес».\n2. Нажмите «Открыть кран», вставьте адрес, выберите 0.5 SOL.\n3. Вернитесь и нажмите «Продолжить».");
        gap(16);
        TextView addr=label(address,15,text,false);addr.setTypeface(Typeface.MONOSPACE);addr.setTextIsSelectable(true);addr.setPadding(dp(14),dp(12),dp(14),dp(12));addr.setBackground(round(surface,12));page.addView(addr,full());
        gap(6);page.addView(label("Баланс: "+bal+" SOL",14,muted,false));
        gap(20);
        secondary("Скопировать адрес",()->{((ClipboardManager)getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText("Devnet address",address));Toast.makeText(this,"Адрес скопирован",Toast.LENGTH_SHORT).show();});
        gap(12);
        secondary("Открыть кран",()->{try{startActivity(new Intent(Intent.ACTION_VIEW,android.net.Uri.parse("https://faucet.solana.com/")));}catch(RuntimeException none){Toast.makeText(this,"Откройте faucet.solana.com в браузере",Toast.LENGTH_LONG).show();}});
        gap(12);
        primary("Продолжить",()->registering(n));
    }

    private void restore(){
        clear();secure(true);
        title("Восстановить ник");
        body("Введите 12 слов через пробел (или 24, если ник создан в прежней версии). Скриншот этого экрана запрещён.");
        gap(20);
        EditText in=new EditText(this);in.setMinLines(4);in.setGravity(Gravity.TOP);in.setSaveEnabled(false);
        in.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);
        in.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_MULTI_LINE|InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS|InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD);
        in.setImeOptions(EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING);in.setFilters(new InputFilter[]{new InputFilter.LengthFilter(512)});
        page.addView(in,full());
        gap(24);
        primary("Восстановить",()->{String words=in.getText().toString().trim().toLowerCase(Locale.ROOT).replaceAll("\\s+"," ");in.setText("");
            busy("Ищем ваш ник в Solana…");
            run((s,t)->{
                if(s.load()==null){
                    JSONObject r=SolanaBridge.run(new JSONObject().put("op","recover").put("mnemonic",words));
                    s.save(new JSONObject().put("entropy",r.getString("entropy")).put("program",DevnetRpc.PROGRAM).put("genesis",DevnetRpc.GENESIS).put("backup",true).put("attempts",new JSONArray()));
                }
                RegistrationFlow.check(s,new DevnetRpc());
                post(t,this::resume);return null;
            });
        });
        gap(12);secondary("Назад",this::start);
    }

    private void server(String n){
        clear();secure(false);
        title("@"+n);body("Ник подтверждён. Теперь выберите, где будет ваша переписка.");
        gap(24);
        card("Общий сервер ParanoID","Быстрый старт. Сервер поддерживаем мы.",true,()->join(n,false));
        gap(12);
        card("Войти по приглашению","Сервер друга или команды — по ссылке или QR. Скоро.",false,null);
        gap(12);
        card("Создать свой сервер","Развернуть ParanoID на своём VPS и приглашать людей. Скоро.",false,null);
    }

    private void join(String n,boolean replace){
        busy("Входим как @"+n+"…");
        org.paranoid.text.TextEngine engine=org.paranoid.text.TextEngine.get(getApplicationContext());
        run((s,t)->{
            String entropy=RegistrationFlow.required(s).getString("entropy");
            String mode=engine.identityLogin((device,http)->IdentityLogin.run(device,http,entropy,n,replace));
            post(t,()->{
                if(IdentityLogin.ACTIVE.equals(mode)){done(n);return;}
                if(IdentityLogin.REPLACE_REQUIRED.equals(mode)){
                    new AlertDialog.Builder(this).setTitle("@"+n+" уже на другом телефоне").setMessage("Перенести ник на этот телефон? Старый телефон будет отключён от ника и больше не сможет войти.")
                        .setPositiveButton("Перенести",(d,x)->join(n,true)).setNegativeButton("Отмена",(d,x)->server(n)).setCancelable(false).show();return;}
                failure(IdentityLogin.REVOKED.equals(mode)?"Этот телефон был отключён от ника. Нужна новая установка приложения.":"Сервер запретил вход для этого ника.",()->server(n));
            });return null;
        });
    }

    private void done(String n){
        clear();secure(false);
        title("Готово");body("Вы вошли как @"+n+". Добавьте контакт по QR-коду и начинайте переписку.");
        gap(32);primary("Открыть чаты",this::finish);
    }

    /** The built-in identity-v3 server acts as the Devnet sponsor over its pinned TLS. */
    private static RegistrationFlow.Sponsor sponsor(){
        String realm=org.paranoid.text.KeyClient.IDENTITY_TEST_REALM,pin=org.paranoid.text.KeyClient.IDENTITY_TEST_PIN;
        return new RegistrationFlow.Sponsor(){
            public JSONObject prepare()throws Exception{
                return org.paranoid.text.KeyTransport.call(realm,pin,"POST","/v3/sponsor/prepare",new JSONObject().put("genesis",DevnetRpc.GENESIS).toString(),null);
            }
            public String cosign(String owner,String name,String blockhash,String ownerSignature)throws Exception{
                return org.paranoid.text.KeyTransport.call(realm,pin,"POST","/v3/sponsor/register",new JSONObject().put("owner",owner).put("name",name)
                    .put("blockhash",blockhash).put("owner_signature",ownerSignature).toString(),null).getString("payer_signature");
            }
        };
    }
    // ---------- helpers ----------
    private static long balance(DevnetRpc rpc,String owner)throws Exception{
        return RegistrationFlow.integer(((JSONObject)rpc.call("getBalance",new JSONArray().put(owner).put(new JSONObject().put("commitment","confirmed")))).get("value"));
    }
    private interface Fail { void on(long ticket,String code); }
    private void run(Step step){run(step,null);}
    private void run(Step step,Fail fail){
        final long ticket=generation.next();
        OWNER.execute(()->{
            try{if(store==null)store=new DevnetStore(getApplicationContext());step.run(store,ticket);}
            catch(Throwable e){
                String code=e.getMessage()==null?"":e.getMessage();
                if(fail!=null&&e instanceof Exception){post(ticket,()->fail.on(ticket,code));return;}
                String msg=e instanceof LinkageError?"Раздел Solana недоступен в этой сборке.":DevnetWork.run(()->{throw e instanceof Exception?(Exception)e:new IOException(e);});
                post(ticket,()->failure(msg,this::resume));
            }
        });
    }
    private void post(long ticket,Runnable r){runOnUiThread(()->{if(generation.current(ticket)&&!isFinishing()&&!isDestroyed())r.run();});}
    private void say(long ticket,TextView v,String s){post(ticket,()->v.setText(s));}
    private void failure(String message,Runnable retry){
        clear();secure(false);title("Не получилось");
        TextView m=label(message,16,muted,false);m.setTextIsSelectable(true);page.addView(m);
        gap(24);primary("Повторить",retry);gap(12);secondary("В начало",this::resume);
    }
    private void busy(String message){clear();gap(80);ProgressBar p=new ProgressBar(this);page.addView(p);gap(16);TextView t=label(message,16,muted,false);t.setGravity(Gravity.CENTER);page.addView(t,full());}
    private void secure(boolean on){if(on)getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_SECURE);}
    private void clear(){page.removeAllViews();}
    private void step(String s){page.addView(label(s,13,accent,true));gap(8);}
    private void title(String s){page.addView(label(s,30,text,true));gap(12);}
    private void body(String s){TextView v=label(s,16,muted,false);v.setTextIsSelectable(true);v.setLineSpacing(0,1.2f);page.addView(v);}
    private void gap(int h){page.addView(new View(this),new LinearLayout.LayoutParams(1,dp(h)));}
    private TextView label(String s,int size,int color,boolean bold){TextView v=new TextView(this);v.setText(s);v.setTextSize(size);v.setTextColor(color);if(bold)v.setTypeface(Typeface.DEFAULT_BOLD);return v;}
    private LinearLayout.LayoutParams full(){return new LinearLayout.LayoutParams(-1,-2);}
    private GradientDrawable round(int color,int r){GradientDrawable g=new GradientDrawable();g.setColor(color);g.setCornerRadius(dp(r));return g;}
    private void primary(String s,Runnable r){Button b=new Button(this);b.setText(s);b.setAllCaps(false);b.setTextSize(17);b.setTextColor(0xffffffff);b.setBackground(round(accent,14));b.setMinHeight(dp(54));b.setOnClickListener(v->r.run());page.addView(b,full());}
    private void secondary(String s,Runnable r){Button b=new Button(this);b.setText(s);b.setAllCaps(false);b.setTextSize(17);b.setTextColor(accent);b.setBackground(round(surface,14));b.setMinHeight(dp(54));b.setOnClickListener(v->r.run());page.addView(b,full());}
    private void card(String head,String sub,boolean enabled,Runnable r){
        LinearLayout c=new LinearLayout(this);c.setOrientation(LinearLayout.VERTICAL);c.setPadding(dp(18),dp(16),dp(18),dp(16));c.setBackground(round(surface,16));
        c.addView(label(head,18,text,true));TextView s=label(sub,14,muted,false);s.setPadding(0,dp(4),0,0);c.addView(s);
        c.setAlpha(enabled?1f:.5f);c.setEnabled(enabled);if(enabled){c.setClickable(true);c.setOnClickListener(v->r.run());}
        page.addView(c,full());
    }
    private int dp(int v){return Math.round(v*getResources().getDisplayMetrics().density);}
}
