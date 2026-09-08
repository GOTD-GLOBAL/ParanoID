package org.paranoid.text;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputFilter;
import android.text.InputType;
import android.view.View;
import android.widget.*;
import org.json.JSONArray;
import org.json.JSONObject;

public final class MainActivity extends Activity implements TextEngine.Listener {
    private TextEngine engine;
    private EditText endpoint,credential,serverPin,peerCode,draft;
    private TextView publicCode,history,status;
    private Spinner role;
    private Button configure,pair,send,copy;
    private boolean paired=false,broken=false,sending=false,configured=false;
    private final Handler handler=new Handler(Looper.getMainLooper());
    private final Runnable poll=new Runnable(){public void run(){engine.sync();handler.postDelayed(this,3000);}};
    @Override public void onCreate(Bundle bundle) {
        super.onCreate(bundle);engine=TextEngine.get(this);
        ScrollView scroll=new ScrollView(this);LinearLayout root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);
        int pad=(int)(16*getResources().getDisplayMetrics().density);root.setPadding(pad,pad,pad,pad);scroll.addView(root);setContentView(scroll);
        TextView title=label(root,"ParanoID — тестовая переписка");title.setTextSize(23);
        label(root,"Только тестовые данные. До 200 сообщений на клиенте. Без восстановления ключей. Фоновая доставка не гарантируется.");
        status=label(root,"Загрузка локального состояния…");
        endpoint=input(root,"HTTPS-адрес сервера",512);endpoint.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_URI);endpoint.setSingleLine(true);
        serverPin=input(root,"Публичный SHA-256 SPKI ключа сервера (64 hex)",64);serverPin.setSingleLine(true);
        label(root,"IP без домена поддерживается. Сверьте отпечаток с владельцем сервера до сохранения; автоматически он не заменяется.");
        role=new Spinner(this);role.setAdapter(new ArrayAdapter<>(this,android.R.layout.simple_spinner_dropdown_item,new String[]{"Телефон 1 — alice","Телефон 2 — bob"}));root.addView(role);
        credential=input(root,"Личный токен сервера (64 hex; не публиковать)",64);credential.setSingleLine(true);
        credential.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_PASSWORD);credential.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);
        configure=button(root,"Сохранить подключение",()->{
            engine.configure(endpoint.getText().toString(),credential.getText().toString(),role.getSelectedItemPosition()==0?"alice":"bob",serverPin.getText().toString());credential.setText("");
        });
        label(root,"Мой публичный код — передайте и сравните на втором телефоне:");
        publicCode=label(root,"");publicCode.setTextIsSelectable(true);publicCode.setTextSize(11);
        copy=button(root,"Копировать публичный код",()->{
            ClipboardManager clipboard=(ClipboardManager)getSystemService(CLIPBOARD_SERVICE);
            clipboard.setPrimaryClip(ClipData.newPlainText("ParanoID public pairing code",publicCode.getText()));
        });
        peerCode=input(root,"Вставьте публичный код второго телефона",4096);peerCode.setMinLines(2);
        pair=button(root,"Подтвердить код собеседника",()->{
            String code=peerCode.getText().toString();
            new AlertDialog.Builder(this).setTitle("Проверка собеседника")
                .setMessage("Сравните весь публичный код непосредственно на экране второго телефона. Один пересланный текст не доказывает подлинность. Код действительно совпадает?")
                .setNegativeButton("Отмена",null).setPositiveButton("Код совпадает",(d,w)->engine.pair(code)).show();
        });
        label(root,"Переписка: … очередь; ✓ сервер сохранил; ✓✓ собеседник сохранил (не прочтение)");
        history=label(root,"");history.setTextIsSelectable(true);
        draft=input(root,"Сообщение",2048);draft.setMinLines(2);
        send=button(root,"Отправить",()->{
            String text=draft.getText().toString();if(text.isEmpty() || sending)return;
            sending=true;updateButtons();engine.send(text,committed->{
                if(committed && draft.getText().toString().equals(text))draft.setText("");
                sending=false;updateButtons();
            });
        });
        button(root,"Синхронизировать сейчас",()->engine.sync());updateButtons();
    }
    private TextView label(LinearLayout root,String text){TextView v=new TextView(this);v.setText(text);v.setTextSize(15);v.setPadding(0,8,0,8);root.addView(v);return v;}
    private EditText input(LinearLayout root,String hint,int limit){EditText v=new EditText(this);v.setHint(hint);v.setFilters(new InputFilter[]{new InputFilter.LengthFilter(limit)});root.addView(v);return v;}
    private Button button(LinearLayout root,String text,Runnable action){Button v=new Button(this);v.setText(text);v.setOnClickListener(w->action.run());root.addView(v);return v;}
    private void updateButtons(){if(send==null)return;send.setEnabled(configured&&paired&&!broken&&!sending);pair.setEnabled(configured&&!broken);copy.setEnabled(configured&&!broken);configure.setEnabled(!broken);}
    @Override public void changed(JSONObject view,String message) {
        try {
            broken=view.optBoolean("broken");configured=view.optBoolean("configured");paired=view.optBoolean("paired");
            status.setText(broken?"Локальное состояние недоступно. Данные не удалены; автоматического сброса ключей нет.":message);
            if(configured && view.has("public")) {
                JSONObject pub=view.getJSONObject("public");publicCode.setText(pub.toString());
                endpoint.setText(view.getString("realm"));endpoint.setEnabled(false);serverPin.setText(view.getString("tls_pin"));serverPin.setEnabled(false);role.setSelection(pub.getString("device").equals("alice")?0:1);role.setEnabled(false);
                JSONArray entries=view.getJSONArray("messages");StringBuilder text=new StringBuilder();
                for(int i=0;i<entries.length();i++) {
                    JSONObject entry=entries.getJSONObject(i);boolean mine=entry.getString("author").equals(pub.getString("device"));
                    String checks=mine?(entry.getBoolean("delivered")?" ✓✓":entry.getBoolean("accepted")?" ✓":" …"):"";
                    text.append(mine?"Я":"Собеседник").append(checks).append(": ").append(entry.getString("text")).append("\n\n");
                }
                history.setText(text.toString());
            }
            updateButtons();
        } catch(Exception ignored){status.setText("Ошибка отображения; локальные данные не сбрасываются.");}
    }
    @Override public void onResume(){super.onResume();engine.listen(this);handler.post(poll);}
    @Override public void onPause(){handler.removeCallbacks(poll);engine.unlisten(this);super.onPause();}
}
