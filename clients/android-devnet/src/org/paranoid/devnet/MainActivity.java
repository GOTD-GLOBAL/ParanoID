package org.paranoid.devnet;

import android.app.*;
import android.os.Bundle;
import android.text.InputFilter;
import android.view.*;
import android.view.inputmethod.EditorInfo;
import android.widget.*;
import android.util.Base64;
import java.io.IOException;
import java.security.SecureRandom;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import org.json.*;

/** Internal Devnet nickname screen in the main messenger. Not server login/Mainnet. */
public final class MainActivity extends Activity {
    private static final ExecutorService OWNER=Executors.newSingleThreadExecutor();
    private static DevnetStore store;
    private TextView status;
    private final UiGeneration generation=new UiGeneration();
    private EditText name;
    private LinearLayout controls;
    private interface Work { String run(DevnetStore s,long ticket)throws Exception; }
    @Override public void onCreate(Bundle bundle) {
        super.onCreate(bundle);getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        ScrollView scroll=new ScrollView(this);LinearLayout root=new LinearLayout(this);root.setOrientation(1);root.setPadding(24,40,24,24);scroll.addView(root);setContentView(scroll);
        TextView heading=new TextView(this);heading.setText("ParanoID · Ник в Devnet\nЗарегистрируйте уникальный ник в тестовой сети Solana. Только тестовые SOL.\nЧаты и звонки используют прежний ID. Эти 24 слова восстанавливают ник, не переписку.");root.addView(heading);
        status=new TextView(this);status.setTextIsSelectable(true);status.setPadding(0,24,0,24);root.addView(status);
        name=new EditText(this);name.setHint("Ник: a-z, 0-9, _, от 3 до 24 символов");name.setSingleLine(true);name.setFilters(new InputFilter[]{new InputFilter.LengthFilter(24)});name.setSaveEnabled(false);root.addView(name);
        controls=new LinearLayout(this);controls.setOrientation(1);root.addView(controls);
        button("Вернуться в ParanoID",this::finish);
        button("Создать ключ для ника",()->create());
        button("Восстановить по 24 словам",()->recover());
        button("Показать recovery-фразу",()->backup());
        button("Получить тестовые SOL (одна попытка)",()->fund());
        button("Копировать адрес для тестовых SOL",()->work((s,ticket)->{
            String address=nativeCall("identity","entropy",required(s).getString("entropy")).getString("owner");
            post(ticket,()->{android.content.ClipboardManager c=(android.content.ClipboardManager)getSystemService(CLIPBOARD_SERVICE);c.setPrimaryClip(android.content.ClipData.newPlainText("Devnet public address",address));});
            return "Публичный адрес скопирован. Пополняйте только в Devnet.\n"+address;
        }));
        button("Зарегистрировать ник",()->confirmRegister());
        button("Проверить ник",()->work((s,ticket)->check(s)));
        work((s,ticket)->{JSONObject state=s.load();return state==null?"Создайте или восстановите тестовую identity.":describe(state);});
    }
    private void button(String text,Runnable r){Button b=new Button(this);b.setText(text);b.setOnClickListener(v->r.run());controls.addView(b);}
    private void enabled(boolean yes){for(int i=0;i<controls.getChildCount();i++)controls.getChildAt(i).setEnabled(yes);name.setEnabled(yes);}
    private void post(long ticket,Runnable r){runOnUiThread(()->{if(generation.current(ticket)&&!isFinishing()&&!isDestroyed())r.run();});}
    @Override public void onDestroy(){generation.next();super.onDestroy();}
    private void work(Work action){final long ticket=generation.next();enabled(false);status.setText("Выполняется…");OWNER.execute(()->{
        final String result=DevnetWork.run(()->{if(store==null)store=new DevnetStore(getApplicationContext());return action.run(store,ticket);});
        post(ticket,()->{status.setText(result);enabled(true);});
    });}
    private static JSONObject nativeCall(String op,String field,String value)throws Exception{return SolanaBridge.run(new JSONObject().put("op",op).put(field,value));}
    private static JSONObject required(DevnetStore s)throws Exception {JSONObject state=s.load();if(state==null)throw new IOException("identity_required");return state;}
    private static String describe(JSONObject s)throws Exception {JSONObject p=nativeCall("identity","entropy",s.getString("entropy"));return "DEVNET\nАдрес: "+p.getString("owner")+"\n"+(s.optBoolean("verified")?"Ранее проверен ник @"+s.optString("name")+"; для свежего состояния нажмите проверку.":"Регистрация ещё не подтверждена.");}
    private void create(){work((s,ticket)->{if(s.load()!=null)throw new IOException("identity_already_exists");byte[] entropy=new byte[32];new SecureRandom().nextBytes(entropy);String e=Base64.encodeToString(entropy,Base64.NO_WRAP);Arrays.fill(entropy,(byte)0);JSONObject p=nativeCall("export_mnemonic","entropy",e);JSONObject state=new JSONObject().put("entropy",e).put("program",DevnetRpc.PROGRAM).put("genesis",DevnetRpc.GENESIS).put("backup",false).put("attempts",new JSONArray());s.save(state);String words=p.getString("mnemonic");post(ticket,()->showWords(words));return describe(state)+"\nСохраните 24 слова до регистрации.";});}
    private void showWords(String words) {
        TextView view=new TextView(this);view.setText(words);view.setPadding(24,24,24,24);view.setSaveEnabled(false);view.setTextIsSelectable(false);
        AlertDialog d=new AlertDialog.Builder(this).setTitle("Только Devnet · сохраните 24 слова").setMessage("Без слов контроль identity не восстановить. Не используйте эту фразу для реальных средств. История переписки из неё не восстанавливается.").setView(view).setPositiveButton("Я записал слова",(a,b)->work((s,ticket)->{JSONObject v=required(s);v.put("backup",true);s.save(v);return describe(v);})).setNegativeButton("Позже",null).create();d.setOnDismissListener(x->view.setText(""));d.show();d.getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
    }
    private void backup(){work((s,ticket)->{JSONObject p=nativeCall("export_mnemonic","entropy",required(s).getString("entropy"));String words=p.getString("mnemonic");post(ticket,()->showWords(words));return "Recovery-фраза показана только на этом устройстве.";});}
    private void recover(){EditText input=new EditText(this);input.setSaveEnabled(false);input.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);input.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS|android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD);input.setImeOptions(EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING);input.setFilters(new InputFilter[]{new InputFilter.LengthFilter(512)});
        AlertDialog d=new AlertDialog.Builder(this).setTitle("Восстановить TEST identity").setMessage("Только фраза ParanoID Devnet. Не вводите фразу реального кошелька.").setView(input).setPositiveButton("Восстановить",(a,b)->{String words=input.getText().toString().trim().toLowerCase(Locale.ROOT);input.setText("");work((s,ticket)->{if(s.load()!=null)throw new IOException("identity_already_exists");JSONObject r=nativeCall("recover","mnemonic",words);JSONObject state=new JSONObject().put("entropy",r.getString("entropy")).put("program",DevnetRpc.PROGRAM).put("genesis",DevnetRpc.GENESIS).put("backup",true).put("attempts",new JSONArray());s.save(state);return describe(state);});}).setNegativeButton("Отмена",null).create();d.setOnDismissListener(x->input.setText(""));d.show();d.getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
    }
    private void fund(){work((s,ticket)->{JSONObject state=required(s);if(state.optBoolean("faucet_attempted"))throw new IOException("faucet_attempt_already_used");DevnetRpc rpc=new DevnetRpc();rpc.cluster();rpc.program();String owner=nativeCall("identity","entropy",state.getString("entropy")).getString("owner");state.put("faucet_attempted",true);s.save(state);rpc.call("requestAirdrop",new JSONArray().put(owner).put(100_000_000L));return "Запрос тестовых SOL отправлен. Это не подтверждение регистрации. Проверьте баланс.";});}
    private void confirmRegister(){String n=name.getText().toString().toLowerCase(Locale.ROOT);if(!n.matches("[a-z][a-z0-9_]{2,23}")){status.setText("Неверный ник.");return;}new AlertDialog.Builder(this).setTitle("Зарегистрировать @"+n+"?").setMessage("Только Devnet. Один ник на identity; переименование пока недоступно. Расход ограничен 0.01 тестового SOL плюс комиссия не более 0.0001 тестового SOL.").setPositiveButton("Подтверждаю",(a,b)->work((s,ticket)->register(s,n))).setNegativeButton("Отмена",null).show();}
    private static String check(DevnetStore store)throws Exception { return RegistrationFlow.check(store,new DevnetRpc()); }
    private static String register(DevnetStore store,String name)throws Exception { return RegistrationFlow.register(store,new DevnetRpc(),name); }
}
