package org.paranoid.text;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputFilter;

import android.view.View;
import android.widget.*;
import org.json.JSONArray;
import org.json.JSONObject;

public final class MainActivity extends Activity implements TextEngine.Listener {
    private TextEngine engine;
    private EditText peerCode,draft;
    private TextView publicCode,history,status;
    private TextView fingerprint;
    private ImageView qr;
    private String displayedQr="";
    private Button configure,pair,send,copy,grant;
    private boolean active=false,identity=false;
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
        label(root,"Создайте ID на телефоне. Для закрытого теста оператор один раз проверит ваш публичный запрос. После одобрения вход выполняется ключом автоматически. Телефон, email и пароль не нужны.");
        configure=button(root,"Создать ID / включить ключевой вход",()->engine.createIdentity());
        label(root,"Публичный запрос оператору (до одобрения) / контакт (после одобрения):");
        publicCode=label(root,"");publicCode.setTextIsSelectable(true);publicCode.setTextSize(11);
        fingerprint=label(root,"");fingerprint.setTextIsSelectable(true);
        qr=new ImageView(this);qr.setAdjustViewBounds(true);root.addView(qr,new LinearLayout.LayoutParams(-1,-2));
        copy=button(root,"Копировать публичный код",()->{
            ClipboardManager clipboard=(ClipboardManager)getSystemService(CLIPBOARD_SERVICE);
            clipboard.setPrimaryClip(ClipData.newPlainText("ParanoID public pairing code",publicCode.getText()));
        });
        peerCode=input(root,"Публичное одобрение оператора или код контакта",4096);peerCode.setMinLines(2);
        grant=button(root,"Принять публичное одобрение",()->engine.importGrant(peerCode.getText().toString()));
        button(root,"Сканировать QR одобрения",()->startActivityForResult(new android.content.Intent(this,QrScanActivity.class),44));
        button(root,"Сканировать QR контакта",()->startActivityForResult(new android.content.Intent(this,QrScanActivity.class),45));
        pair=button(root,"Подтвердить код собеседника",()->{
            String code=peerCode.getText().toString();
            confirmContact(code);
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
    private void confirmContact(String code){engine.previewContact(code,preview->{
        if(isFinishing()||isDestroyed())return;
        new AlertDialog.Builder(this).setTitle("Проверка собеседника")
            .setMessage("Сравните этот полный отпечаток с экраном второго телефона по доверенному каналу. Пересланный QR не доказывает личность.\n\n"+preview.optString("fingerprint"))
            .setNegativeButton("Отмена",null).setPositiveButton("Отпечаток совпадает",(d,w)->engine.pair(code)).show();
    });}
    @Override protected void onActivityResult(int request,int result,android.content.Intent data){
        super.onActivityResult(request,result,data);
        if(result!=RESULT_OK||data==null)return;String raw=data.getStringExtra("public_qr");
        if(raw==null||raw.length()>4096)return;
        if(request==44)engine.importGrant(raw);else if(request==45)confirmContact(raw);
    }
    private void updateButtons(){if(send==null)return;send.setEnabled(active&&paired&&!broken&&!sending);pair.setEnabled(active&&!broken);copy.setEnabled(identity&&!broken);grant.setEnabled(identity&&!active&&!broken);configure.setEnabled(!broken&&!identity);}
    @Override public void changed(JSONObject view,String message) {
        try {
            broken=view.optBoolean("broken");configured=view.optBoolean("configured");paired=view.optBoolean("paired");
            active=view.optBoolean("active");identity=view.optBoolean("identity");
            status.setText(broken?"Локальное состояние недоступно. Данные не удалены; автоматического сброса ключей нет.":message);
            if(identity&&!active)status.append("\nОжидание одобрения / активации. ID уже сохранён. Повторная попытка не создаёт новые ключи.");
            if(configured && view.has("public")) {
                JSONObject pub=view.getJSONObject("public");
                JSONObject descriptor=view.optJSONObject(active?"contact":"request");
                publicCode.setText(descriptor==null?"Сохранённая старая идентичность; включите ключевой вход без сброса данных.":descriptor.toString());
                if(descriptor!=null) {
                    String raw=descriptor.toString();
                    if(!raw.equals(displayedQr)) {
                        byte[] luma=QrCodec.encode(raw,640);int[] pixels=new int[luma.length];
                        for(int n=0;n<pixels.length;n++)pixels[n]=(luma[n]&255)==0?0xff000000:0xffffffff;
                        qr.setImageBitmap(android.graphics.Bitmap.createBitmap(pixels,640,640,android.graphics.Bitmap.Config.ARGB_8888));displayedQr=raw;
                    }
                    fingerprint.setText(active?"Отпечаток контакта:\n"+view.optString("contact_fingerprint"):"Мой ID:\n"+descriptor.getJSONObject("credential").getString("account"));
                }
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
