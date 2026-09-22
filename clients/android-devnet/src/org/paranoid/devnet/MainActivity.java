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

/** Registration-only Devnet candidate. Not messenger login and never Mainnet. */
public final class MainActivity extends Activity {
    private static final ExecutorService OWNER=Executors.newSingleThreadExecutor();
    private static DevnetStore store;
    private TextView status;
    private EditText name;
    private LinearLayout controls;
    private interface Work { String run(DevnetStore s)throws Exception; }
    @Override public void onCreate(Bundle bundle) {
        super.onCreate(bundle);getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        ScrollView scroll=new ScrollView(this);LinearLayout root=new LinearLayout(this);root.setOrientation(1);root.setPadding(24,40,24,24);scroll.addView(root);setContentView(scroll);
        TextView heading=new TextView(this);heading.setText("ParanoID · SOLANA DEVNET\nТестовая регистрация. Не отправляйте реальные SOL.\nЭто отдельный прототип, не вход в мессенджер.");root.addView(heading);
        status=new TextView(this);status.setTextIsSelectable(true);status.setPadding(0,24,0,24);root.addView(status);
        name=new EditText(this);name.setHint("Ник: a-z, 0-9, _, от 3 до 24 символов");name.setSingleLine(true);name.setFilters(new InputFilter[]{new InputFilter.LengthFilter(24)});name.setSaveEnabled(false);root.addView(name);
        controls=new LinearLayout(this);controls.setOrientation(1);root.addView(controls);
        button("Создать новую Devnet identity",()->create());
        button("Восстановить по 24 словам",()->recover());
        button("Показать recovery-фразу",()->backup());
        button("Получить тестовые SOL (одна попытка)",()->fund());
        button("Зарегистрировать ник",()->confirmRegister());
        button("Проверить Devnet / результат",()->work(s->check(s)));
        work(s->{JSONObject state=s.load();return state==null?"Создайте или восстановите тестовую identity.":describe(state);});
    }
    private void button(String text,Runnable r){Button b=new Button(this);b.setText(text);b.setOnClickListener(v->r.run());controls.addView(b);}
    private void enabled(boolean yes){for(int i=0;i<controls.getChildCount();i++)controls.getChildAt(i).setEnabled(yes);name.setEnabled(yes);}
    private void post(Runnable r){runOnUiThread(()->{if(!isFinishing()&&!isDestroyed())r.run();});}
    private void work(Work action){enabled(false);status.setText("Выполняется…");OWNER.execute(()->{
        String text;try{if(store==null)store=new DevnetStore(getApplicationContext());text=action.run(store);}catch(Exception e){String code=e.getMessage();text="Операция не завершена: "+(e instanceof IOException&&code!=null&&code.matches("[a-z_]{1,60}")?code:e.getClass().getSimpleName())+"\nПри отправленной транзакции результат может оставаться неизвестным. Нажмите проверку, не создавайте другую identity.";}
        final String result=text;post(()->{status.setText(result);enabled(true);});
    });}
    private static JSONObject nativeCall(String op,String field,String value)throws Exception{return SolanaBridge.run(new JSONObject().put("op",op).put(field,value));}
    private static JSONObject required(DevnetStore s)throws Exception {JSONObject state=s.load();if(state==null)throw new IOException("identity_required");return state;}
    private static String describe(JSONObject s)throws Exception {JSONObject p=nativeCall("identity","entropy",s.getString("entropy"));return "DEVNET\nАдрес: "+p.getString("owner")+"\n"+(s.optBoolean("verified")?"Ранее проверен ник @"+s.optString("name")+"; для свежего состояния нажмите проверку.":"Регистрация ещё не подтверждена.");}
    private void create(){work(s->{if(s.load()!=null)throw new IOException("identity_already_exists");byte[] entropy=new byte[32];new SecureRandom().nextBytes(entropy);String e=Base64.encodeToString(entropy,Base64.NO_WRAP);Arrays.fill(entropy,(byte)0);JSONObject p=nativeCall("export_mnemonic","entropy",e);JSONObject state=new JSONObject().put("entropy",e).put("program",DevnetRpc.PROGRAM).put("genesis",DevnetRpc.GENESIS).put("backup",false).put("attempts",new JSONArray());s.save(state);String words=p.getString("mnemonic");post(()->showWords(words));return describe(state)+"\nСохраните 24 слова до регистрации.";});}
    private void showWords(String words) {
        TextView view=new TextView(this);view.setText(words);view.setPadding(24,24,24,24);view.setSaveEnabled(false);view.setTextIsSelectable(false);
        AlertDialog d=new AlertDialog.Builder(this).setTitle("Только Devnet · сохраните 24 слова").setMessage("Без слов контроль identity не восстановить. Не используйте эту фразу для реальных средств. История переписки из неё не восстанавливается.").setView(view).setPositiveButton("Я записал слова",(a,b)->work(s->{JSONObject v=required(s);v.put("backup",true);s.save(v);return describe(v);})).setNegativeButton("Позже",null).create();d.setOnDismissListener(x->view.setText(""));d.show();d.getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
    }
    private void backup(){work(s->{JSONObject p=nativeCall("export_mnemonic","entropy",required(s).getString("entropy"));String words=p.getString("mnemonic");post(()->showWords(words));return "Recovery-фраза показана только на этом устройстве.";});}
    private void recover(){EditText input=new EditText(this);input.setSaveEnabled(false);input.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);input.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS|android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD);input.setImeOptions(EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING);input.setFilters(new InputFilter[]{new InputFilter.LengthFilter(512)});
        AlertDialog d=new AlertDialog.Builder(this).setTitle("Восстановить TEST identity").setMessage("Только фраза ParanoID Devnet. Не вводите фразу реального кошелька.").setView(input).setPositiveButton("Восстановить",(a,b)->{String words=input.getText().toString();input.setText("");work(s->{if(s.load()!=null)throw new IOException("identity_already_exists");JSONObject r=nativeCall("recover","mnemonic",words);JSONObject state=new JSONObject().put("entropy",r.getString("entropy")).put("program",DevnetRpc.PROGRAM).put("genesis",DevnetRpc.GENESIS).put("backup",true).put("attempts",new JSONArray());s.save(state);return describe(state);});}).setNegativeButton("Отмена",null).create();d.setOnDismissListener(x->input.setText(""));d.show();d.getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
    }
    private void fund(){work(s->{JSONObject state=required(s);if(state.optBoolean("faucet_attempted"))throw new IOException("faucet_attempt_already_used");DevnetRpc rpc=new DevnetRpc();rpc.cluster();rpc.program();String owner=nativeCall("identity","entropy",state.getString("entropy")).getString("owner");state.put("faucet_attempted",true);s.save(state);rpc.call("requestAirdrop",new JSONArray().put(owner).put(100_000_000L));return "Запрос тестовых SOL отправлен. Это не подтверждение регистрации. Проверьте баланс.";});}
    private void confirmRegister(){String n=name.getText().toString().toLowerCase(Locale.ROOT);if(!n.matches("[a-z][a-z0-9_]{2,23}")){status.setText("Неверный ник.");return;}new AlertDialog.Builder(this).setTitle("Зарегистрировать @"+n+"?").setMessage("Только Devnet. Один ник на identity; переименование пока недоступно. Расход ограничен 0.01 тестового SOL плюс комиссия не более 0.0001 тестового SOL.").setPositiveButton("Подтверждаю",(a,b)->work(s->register(s,n))).setNegativeButton("Отмена",null).show();}
    private static long integer(Object value)throws IOException {if(!(value instanceof Long)&&!(value instanceof Integer))throw new IOException("rpc_integer");long n=((Number)value).longValue();if(n<0)throw new IOException("rpc_integer");return n;}
    private static String data(JSONObject account)throws Exception {if(account.getBoolean("executable"))throw new IOException("executable_record");JSONArray a=account.getJSONArray("data");if(a.length()!=2||!"base64".equals(a.getString(1)))throw new IOException("record_encoding");return a.getString(0);}
    private static boolean readback(DevnetRpc rpc,JSONObject state,String owner,String n)throws Exception {
        JSONObject lookup=SolanaBridge.run(new JSONObject().put("op","lookup").put("owner",owner).put("name",n));
        JSONArray values=((JSONObject)rpc.call("getMultipleAccounts",new JSONArray().put(new JSONArray().put(lookup.getString("identity")).put(lookup.getString("nickname"))).put(DevnetRpc.finalized().put("encoding","base64")))).getJSONArray("value");
        if(values.length()!=2)throw new IOException("record_count");if(values.isNull(0)&&values.isNull(1))return false;if(values.isNull(0)||values.isNull(1))throw new IOException("name_conflict_or_partial_record");
        JSONObject id=values.getJSONObject(0),nick=values.getJSONObject(1);
        SolanaBridge.run(new JSONObject().put("op","verify").put("owner",owner).put("name",n).put("identity_data",data(id)).put("nickname_data",data(nick)).put("identity_program",id.getString("owner")).put("nickname_program",nick.getString("owner")).put("genesis",DevnetRpc.GENESIS));
        state.put("verified",true).put("name",n);return true;
    }
    private static String recoveredName(DevnetRpc rpc,String identity)throws Exception {
        JSONObject a=rpc.account(identity);if(a==null)return "";byte[] b=Base64.decode(data(a),Base64.NO_WRAP);if(b.length!=128)throw new IOException("record_length");int n=b[74]&255;if(n<3||n>24)throw new IOException("record_length");return new String(b,75,n,StandardCharsets.US_ASCII);
    }
    private static boolean expired(DevnetRpc rpc,JSONArray attempts)throws Exception {
        if(attempts.length()==0)return true;
        JSONArray signatures=new JSONArray();long expiry=0;
        for(int i=0;i<attempts.length();i++){JSONObject a=attempts.getJSONObject(i);signatures.put(a.getString("signature"));expiry=Math.max(expiry,a.getLong("last_valid_height"));}
        rpc.call("getSignatureStatuses",new JSONArray().put(signatures).put(new JSONObject().put("searchTransactionHistory",true)));
        // Status alone never claims success; finalized readback is the authority.
        return integer(rpc.call("getBlockHeight",new JSONArray().put(DevnetRpc.finalized())))>expiry;
    }
    private static String check(DevnetStore store)throws Exception {
        JSONObject s=required(store),p=nativeCall("identity","entropy",s.getString("entropy"));DevnetRpc rpc=new DevnetRpc();rpc.cluster();rpc.program();
        String n=s.optString("name");if(n.isEmpty())n=recoveredName(rpc,p.getString("identity"));
        if(!n.isEmpty()&&readback(rpc,s,p.getString("owner"),n)){store.save(s);return "Подтверждено в DEVNET: @"+n+"\nIdentity: "+p.getString("identity");}
        boolean ended=expired(rpc,s.getJSONArray("attempts"));long balance=integer(((JSONObject)rpc.call("getBalance",new JSONArray().put(p.getString("owner")).put(DevnetRpc.finalized()))).get("value"));
        return describe(s)+"\nБаланс: "+balance+" тестовых lamports.\n"+(ended?"Нет подтверждённой записи. Можно зарегистрировать/повторить выбранный ник.":"Транзакция ещё ожидается. Новую не создаём.");
    }
    private static String register(DevnetStore store,String n)throws Exception {
        JSONObject s=required(store);if(!s.optBoolean("backup"))throw new IOException("backup_confirmation_required");if(!s.optString("name").isEmpty()&&!n.equals(s.getString("name")))throw new IOException("different_name_pending");
        DevnetRpc rpc=new DevnetRpc();String genesis=rpc.cluster();rpc.program();JSONObject p=nativeCall("identity","entropy",s.getString("entropy"));String owner=p.getString("owner");
        if(readback(rpc,s,owner,n)){store.save(s);return "Подтверждено в Devnet: @"+n;}
        JSONArray attempts=s.getJSONArray("attempts");if(attempts.length()>=3)throw new IOException("attempt_limit");if(!expired(rpc,attempts))return "Старая транзакция ещё возможна; нажмите проверку позже.";
        // Re-read AFTER finalized height has passed all recorded attempts.
        if(readback(rpc,s,owner,n)){store.save(s);return "Подтверждено в Devnet: @"+n;}
        JSONObject block=((JSONObject)rpc.call("getLatestBlockhash",new JSONArray().put(DevnetRpc.finalized()))).getJSONObject("value");
        JSONObject tx=SolanaBridge.run(new JSONObject().put("op","register").put("entropy",s.getString("entropy")).put("name",n).put("blockhash",block.getString("blockhash")).put("genesis",genesis));
        long rent=integer(rpc.call("getMinimumBalanceForRentExemption",new JSONArray().put(128).put(DevnetRpc.finalized())));
        long fee=integer(((JSONObject)rpc.call("getFeeForMessage",new JSONArray().put(tx.getString("message")).put(DevnetRpc.finalized()))).get("value"));
        if(rent>5_000_000||fee>100_000)throw new IOException("cost_limit");
        long balance=integer(((JSONObject)rpc.call("getBalance",new JSONArray().put(owner).put(DevnetRpc.finalized()))).get("value"));if(balance<rent*2+fee)throw new IOException("insufficient_devnet_sol");
        JSONObject attempt=new JSONObject().put("signature",tx.getString("signature")).put("transaction",tx.getString("transaction")).put("last_valid_height",integer(block.get("lastValidBlockHeight")));
        attempts.put(attempt);s.put("name",n);store.save(s); // durable before any network submission
        Object signature=rpc.call("sendTransaction",new JSONArray().put(tx.getString("transaction")).put(new JSONObject().put("encoding","base64").put("skipPreflight",false).put("preflightCommitment","finalized").put("maxRetries",0)));
        if(!tx.getString("signature").equals(signature))throw new IOException("signature_reply_mismatch");
        return "Транзакция отправлена, но регистрация ещё НЕ подтверждена.\nНажмите «Проверить Devnet / результат».\n"+tx.getString("signature");
    }
}
