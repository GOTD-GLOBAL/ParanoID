package org.paranoid.devnet;

import android.app.*;
import android.content.*;
import android.graphics.*;
import android.graphics.drawable.*;
import android.os.Bundle;
import android.text.*;
import android.view.*;
import android.view.inputmethod.*;
import android.widget.*;
import org.json.*;
import java.io.IOException;
import java.security.SecureRandom;
import java.util.*;
import java.util.concurrent.*;

/**
 * Onboarding flow aligned with the paranoid.global/prototypes/mobile-messenger/ UX prototype.
 * Screen order: start → words → nick → registering → server → join → done.
 * User-visible strings never mention Solana, Devnet, keypair, blockchain, SOL or transactions.
 */
public final class OnboardingActivity extends Activity {
    private static final ExecutorService OWNER = Executors.newSingleThreadExecutor();
    private static DevnetStore store;
    private final UiGeneration generation = new UiGeneration();
    private LinearLayout page;
    // Theme colours
    private int bg, text, muted, accent, surface, warn, green;

    @Override public void onCreate(Bundle b) {
        super.onCreate(b);
        boolean night = (getResources().getConfiguration().uiMode
            & android.content.res.Configuration.UI_MODE_NIGHT_MASK)
            == android.content.res.Configuration.UI_MODE_NIGHT_YES;
        bg      = night ? 0xff0f0f14 : 0xffffffff;
        text    = night ? 0xfff0f0f0 : 0xff111827;
        muted   = night ? 0xff9aa4b2 : 0xff5b6472;
        accent  = 0xff4f8dff;
        surface = night ? 0xff1a1a22 : 0xfff1f4f9;
        warn    = 0xfff97316;
        green   = 0xff22c55e;
        getWindow().setStatusBarColor(bg);
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setBackgroundColor(bg);
        page = new LinearLayout(this);
        page.setOrientation(LinearLayout.VERTICAL);
        page.setPadding(dp(24), dp(56), dp(24), dp(32));
        scroll.addView(page);
        setContentView(scroll);
        resume();
    }

    @Override public void onDestroy() { generation.next(); super.onDestroy(); }
    @Override public void onBackPressed() { moveTaskToBack(true); }

    // ─── state machine ────────────────────────────────────────────────────
    private void resume() {
        busy("Открываем…");
        run((s, t) -> {
            JSONObject st = s.load();
            if (st == null) { post(t, this::start); return null; }
            if (!st.optBoolean("backup")) {
                String w = SolanaBridge.run(new JSONObject()
                    .put("op", "export_mnemonic")
                    .put("entropy", st.getString("entropy"))).getString("mnemonic");
                post(t, () -> words(w));
                return null;
            }
            if (!st.optBoolean("verified") && st.optString("name").isEmpty()) {
                post(t, () -> nick(null)); return null;
            }
            if (!st.optBoolean("verified")) {
                post(t, () -> registering(st.optString("name"))); return null;
            }
            String nick = st.getString("name");
            post(t, () -> server(nick));
            return null;
        });
    }

    // ─── screen: welcome ──────────────────────────────────────────────────
    private void start() {
        clear(); secure(false);
        spacer(8);
        // Logo area
        FrameLayout logo = new FrameLayout(this);
        logo.setPadding(0, 0, 0, 0);
        TextView icon = makeText("🔒", 48, text, false);
        icon.setGravity(Gravity.CENTER);
        logo.addView(icon);
        page.addView(logo, fullW(dp(72)));
        gap(24);
        // Headline
        heading("Ваши разговоры.\nВаш сервер.");
        gap(10);
        bodyText("Создайте аккаунт без номера телефона и выберите, где будет работать ваш мессенджер.");
        gap(40);
        btnPrimary("Создать аккаунт", this::createKey);
        gap(12);
        btnSecondary("Войти", this::restore);
    }

    // ─── screen: create key (generates entropy, shows words) ──────────────
    private void createKey() {
        busy("Создаём ключ…");
        run((s, t) -> {
            if (s.load() == null) {
                byte[] e = new byte[16];
                new SecureRandom().nextBytes(e);
                String entropy = java.util.Base64.getEncoder().encodeToString(e);
                Arrays.fill(e, (byte) 0);
                s.save(new JSONObject()
                    .put("entropy", entropy)
                    .put("program", DevnetRpc.PROGRAM)
                    .put("genesis", DevnetRpc.GENESIS)
                    .put("backup", false)
                    .put("attempts", new JSONArray()));
            }
            post(t, this::resume);
            return null;
        });
    }

    // ─── screen: words ────────────────────────────────────────────────────
    private void words(String mnemonic) {
        clear(); secure(true);
        progress(1, 3);
        heading("Запишите 12 слов");
        gap(12);
        // Warning panel
        LinearLayout warnBox = boxPanel(0x1af97316, warn);
        TextView warnTxt = makeText(
            "⚠️  Только по ним можно вернуть аккаунт на новом телефоне. "
            + "Запишите на бумаге. Скриншот этого экрана запрещён.",
            14, warn, false);
        warnTxt.setLineSpacing(0, 1.4f);
        warnBox.addView(warnTxt);
        page.addView(warnBox, full());
        gap(16);
        // Words grid
        String[] w = mnemonic.split(" ");
        GridLayout grid = new GridLayout(this);
        grid.setColumnCount(2);
        grid.setPadding(dp(4), dp(4), dp(4), dp(4));
        grid.setBackgroundColor(surface);
        grid.setBackground(rnd(surface, 16));
        for (int i = 0; i < w.length; i++) {
            LinearLayout cell = new LinearLayout(this);
            cell.setOrientation(LinearLayout.HORIZONTAL);
            cell.setPadding(dp(12), dp(10), dp(12), dp(10));
            TextView num = makeText(String.valueOf(i + 1), 12, muted, false);
            num.setMinWidth(dp(24));
            TextView val = makeText(w[i], 15, text, true);
            cell.addView(num);
            cell.addView(val);
            GridLayout.LayoutParams lp = new GridLayout.LayoutParams();
            lp.columnSpec = GridLayout.spec(i % 2, 1f);
            lp.width = 0;
            grid.addView(cell, lp);
        }
        grid.setSaveEnabled(false);
        page.addView(grid, full());
        gap(12);
        // Copy button — owner decision 2026-10-05: allowed to copy (not storing crypto)
        btnSecondary("Скопировать слова", () -> {
            android.content.ClipboardManager cm = (android.content.ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
            cm.setPrimaryClip(android.content.ClipData.newPlainText("paranoid-recovery", mnemonic));
            android.widget.Toast.makeText(this, "Скопировано. Сохраните в надёжном месте.", android.widget.Toast.LENGTH_LONG).show();
        });
        gap(12);
        btnPrimary("Я записал слова", () ->
            new AlertDialog.Builder(this)
                .setTitle("Точно записали?")
                .setMessage("Без этих слов аккаунт не восстановить.")
                .setPositiveButton("Да", (d, x) -> {
                    grid.removeAllViews();
                    busy("Сохраняем…");
                    run((s, t) -> {
                        JSONObject st = RegistrationFlow.required(s);
                        st.put("backup", true);
                        s.save(st);
                        post(t, this::resume);
                        return null;
                    });
                })
                .setNegativeButton("Нет", null)
                .show());
    }

    // ─── screen: nick input ───────────────────────────────────────────────
    private void nick(String error) {
        clear(); secure(false);
        progress(2, 3);
        heading("Выберите ник");
        gap(8);
        bodyText("Ник — ваш уникальный адрес. Сменить потом нельзя.");
        gap(20);
        // @-prefix field
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setBackground(rnd(surface, 14));
        row.setPadding(0, 0, 0, 0);
        TextView at = makeText("@", 24, accent, true);
        at.setPadding(dp(16), dp(16), dp(4), dp(16));
        EditText field = new EditText(this);
        field.setHint("ник");
        field.setSingleLine(true);
        field.setTextSize(22);
        field.setTextColor(text);
        field.setHintTextColor(0x44aaaaaa);
        field.setBackground(null);
        field.setPadding(dp(4), dp(14), dp(16), dp(14));
        field.setInputType(InputType.TYPE_CLASS_TEXT
            | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            | InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD);
        field.setFilters(new InputFilter[]{new InputFilter.LengthFilter(24)});
        row.addView(at);
        row.addView(field, new LinearLayout.LayoutParams(0, -2, 1f));
        page.addView(row, full());
        gap(8);
        if (error != null) {
            page.addView(makeText(error, 13, 0xffef4444, false));
            gap(4);
        }
        // Validation chips
        LinearLayout chips = new LinearLayout(this);
        chips.setOrientation(LinearLayout.HORIZONTAL);
        chips.setGravity(Gravity.START);
        chips.setPadding(0, 0, 0, 0);
        String[] labels = {"3–24 символа", "a–z 0–9 _", "начинается с буквы"};
        TextView[] chipViews = new TextView[3];
        for (int i = 0; i < labels.length; i++) {
            TextView c = chip(labels[i]);
            chipViews[i] = c;
            chips.addView(c);
            if (i < labels.length - 1) chips.addView(spacerH(8));
        }
        page.addView(chips);
        gap(24);
        Button btn = new Button(this);
        btn.setText("Занять ник");
        btn.setAllCaps(false);
        btn.setTextSize(17);
        btn.setTextColor(0xffffffff);
        btn.setBackground(rnd(accent, 14));
        btn.setMinHeight(dp(54));
        btn.setEnabled(false);
        btn.setAlpha(0.5f);
        page.addView(btn, full());
        field.addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence s, int a, int b, int c) {}
            public void onTextChanged(CharSequence s, int a, int b, int c) {}
            public void afterTextChanged(android.text.Editable e) {
                String v = e.toString().toLowerCase(Locale.ROOT);
                boolean len = v.length() >= 3 && v.length() <= 24;
                boolean lat = v.matches("[a-z0-9_]*");
                boolean st  = v.matches("[a-z].*");
                boolean ok  = len && lat && st;
                chipViews[0].setTextColor(len ? green : muted);
                chipViews[1].setTextColor(lat && v.length() > 0 ? green : muted);
                chipViews[2].setTextColor(st  && v.length() > 0 ? green : muted);
                btn.setEnabled(ok);
                btn.setAlpha(ok ? 1f : 0.5f);
            }
        });
        btn.setOnClickListener(v -> {
            String n = field.getText().toString().trim().toLowerCase(Locale.ROOT)
                .replaceAll("[\\s\\u00a0\\u200b-\\u200d\\ufeff]", "");
            if (!n.matches("[a-z][a-z0-9_]{2,23}")) {
                nick("Ник не подходит: только a–z, 0–9 и _, от 3 до 24 символов, первая — буква.");
            } else {
                registering(n);
            }
        });
    }

    // ─── screen: registering (progress) ──────────────────────────────────
    private void registering(String n) {
        clear(); secure(false);
        progress(3, 3);
        heading("Регистрируем\n@" + n);
        gap(16);
        TextView status = makeText("Подключаемся…", 16, muted, false);
        page.addView(status);
        ProgressBar bar = new ProgressBar(this);
        bar.setPadding(0, dp(8), 0, 0);
        page.addView(bar);
        run((s, t) -> {
            DevnetRpc rpc = new DevnetRpc();
            JSONObject st = RegistrationFlow.required(s);
            String owner = SolanaBridge.run(new JSONObject()
                .put("op", "identity").put("entropy", st.getString("entropy")))
                .getString("owner");
            if (st.optString("name").isEmpty() || !st.optBoolean("verified")) {
                RegistrationFlow.check(s, rpc); st = s.load();
            }
            if (!st.optBoolean("verified")) {
                say(t, status, "Создаём аккаунт…");
                try {
                    RegistrationFlow.registerSponsored(s, rpc, sponsor(), n);
                } catch (org.paranoid.text.SyncCycle.Rejected refused) {
                    if (refused.code.equals("sponsor_used"))
                        throw new IOException("name_conflict_or_partial_record");
                    if (balance(rpc, owner) < 5_000_000L)
                        throw new IOException("insufficient_devnet_sol");
                    RegistrationFlow.register(s, rpc, n);
                }
                for (int i = 0; i < 40 && !s.load().optBoolean("verified"); i++) {
                    say(t, status, "Подтверждаем… " + (i * 3) + " с");
                    Thread.sleep(3000);
                    RegistrationFlow.check(s, rpc);
                }
                if (!s.load().optBoolean("verified"))
                    throw new IOException("registration_pending");
            }
            post(t, this::resume);
            return null;
        }, (t, code) -> {
            if ("name_conflict_or_partial_record".equals(code)
                || "identity_already_registered".equals(code)) {
                nick("Ник @" + n + " уже занят. Выберите другой.");
                return;
            }
            if ("insufficient_devnet_sol".equals(code)) { noFunds(n); return; }
            String m = DevnetWork.run(() -> { throw new IOException(code); });
            failure(m.contains("(IOException)")
                ? "Не удалось завершить регистрацию (" + code
                    + "). Нажмите «Повторить»: уже отправленная транзакция не дублируется."
                : m, () -> registering(n));
        });
    }

    private void noFunds(String n) {
        busy("Проверяем…");
        run((s, t) -> {
            String a = SolanaBridge.run(new JSONObject()
                .put("op", "identity")
                .put("entropy", RegistrationFlow.required(s).getString("entropy")))
                .getString("owner");
            String bal;
            try { bal = java.math.BigDecimal.valueOf(balance(new DevnetRpc(), a), 9)
                .stripTrailingZeros().toPlainString(); }
            catch (Exception e) { bal = "—"; }
            String shown = bal;
            post(t, () -> noFundsScreen(n, a, shown));
            return null;
        });
    }

    private void noFundsScreen(String n, String address, String bal) {
        clear(); secure(false);
        heading("Временный сбой");
        bodyText("Сервер не смог завершить регистрацию прямо сейчас. Попробуйте чуть позже.");
        gap(24);
        btnPrimary("Повторить", () -> registering(n));
    }

    // ─── screen: restore ─────────────────────────────────────────────────
    private void restore() {
        clear(); secure(true);
        heading("Войти");
        gap(8);
        bodyText("Введите 12 слов вашего аккаунта. Экран защищён от скриншотов.");
        gap(20);
        EditText in = new EditText(this);
        in.setMinLines(4);
        in.setGravity(Gravity.TOP | Gravity.START);
        in.setSaveEnabled(false);
        in.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);
        in.setInputType(InputType.TYPE_CLASS_TEXT
            | InputType.TYPE_TEXT_FLAG_MULTI_LINE
            | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            | InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD);
        in.setImeOptions(EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING);
        in.setFilters(new InputFilter[]{new InputFilter.LengthFilter(512)});
        in.setBackground(rnd(surface, 14));
        in.setPadding(dp(16), dp(14), dp(16), dp(14));
        in.setTextSize(16);
        in.setTextColor(text);
        in.setHint("Слово 1 · слово 2 · …");
        in.setHintTextColor(0x44aaaaaa);
        page.addView(in, full());
        gap(24);
        btnPrimary("Восстановить аккаунт", () -> {
            String words = in.getText().toString().trim().toLowerCase(Locale.ROOT)
                .replaceAll("\\s+", " ");
            in.setText("");
            busy("Ищем ваш аккаунт…");
            run((s, t) -> {
                if (s.load() == null) {
                    JSONObject r = SolanaBridge.run(new JSONObject()
                        .put("op", "recover").put("mnemonic", words));
                    s.save(new JSONObject()
                        .put("entropy", r.getString("entropy"))
                        .put("program", DevnetRpc.PROGRAM)
                        .put("genesis", DevnetRpc.GENESIS)
                        .put("backup", true)
                        .put("attempts", new JSONArray()));
                }
                RegistrationFlow.check(s, new DevnetRpc());
                post(t, this::resume);
                return null;
            });
        });
        gap(12);
        btnSecondary("Назад", this::start);
    }

    // ─── screen: choose server ────────────────────────────────────────────
    private void server(String n) {
        clear(); secure(false);
        // Avatar-like success state
        LinearLayout hero = new LinearLayout(this);
        hero.setOrientation(LinearLayout.VERTICAL);
        hero.setGravity(Gravity.CENTER);
        hero.setPadding(0, 0, 0, 0);
        // Avatar circle
        TextView av = makeText(n.substring(0, 1).toUpperCase(Locale.ROOT), 32, 0xffffffff, true);
        av.setGravity(Gravity.CENTER);
        av.setPadding(0, 0, 0, 0);
        GradientDrawable avBg = new GradientDrawable();
        avBg.setShape(GradientDrawable.OVAL);
        avBg.setColor(accent);
        av.setBackground(avBg);
        LinearLayout.LayoutParams avLp = new LinearLayout.LayoutParams(dp(72), dp(72));
        avLp.gravity = Gravity.CENTER_HORIZONTAL;
        hero.addView(av, avLp);
        gap(14);
        TextView nik = makeText("@" + n, 26, text, true);
        nik.setGravity(Gravity.CENTER);
        hero.addView(nik);
        gap(6);
        TextView sub = makeText("Аккаунт готов", 15, green, false);
        sub.setGravity(Gravity.CENTER);
        hero.addView(sub);
        page.addView(hero, full());
        gap(28);
        heading("Выберите сервер");
        gap(8);
        bodyText("Сервер хранит и доставляет ваши сообщения.\nМожно подключить больше серверов позже.");
        gap(20);
        serverCard("🏠", "Общий сервер ParanoID",
            "Быстрый старт. Поддерживаем мы.", true, () -> join(n, false));
        gap(10);
        serverCard("✉️", "Войти по приглашению",
            "Сервер друга или команды — по ссылке или QR.", false, null);
        gap(10);
        serverCard("🚀", "Создать свой сервер",
            "Развернуть ParanoID на своём VPS.", false, null);
    }

    // ─── screen: join (login) ─────────────────────────────────────────────
    private void join(String n, boolean replace) {
        busy("Подключаемся…");
        org.paranoid.text.TextEngine engine =
            org.paranoid.text.TextEngine.get(getApplicationContext());
        run((s, t) -> {
            String entropy = RegistrationFlow.required(s).getString("entropy");
            String mode = engine.identityLogin(
                (device, http) -> IdentityLogin.run(device, http, entropy, n, replace));
            post(t, () -> {
                if (IdentityLogin.ACTIVE.equals(mode)) { done(n); return; }
                if (IdentityLogin.REPLACE_REQUIRED.equals(mode)) {
                    new AlertDialog.Builder(this)
                        .setTitle("@" + n + " уже на другом телефоне")
                        .setMessage("Перенести аккаунт на этот телефон? "
                            + "Старый телефон будет отключён.")
                        .setPositiveButton("Перенести", (d, x) -> join(n, true))
                        .setNegativeButton("Отмена", (d, x) -> server(n))
                        .setCancelable(false).show();
                    return;
                }
                failure(IdentityLogin.REVOKED.equals(mode)
                    ? "Этот телефон был отключён от аккаунта. Нужна новая установка приложения."
                    : "Сервер отказал во входе.",
                    () -> server(n));
            });
            return null;
        }, (t, code) -> {
            String m = DevnetWork.run(() -> { throw new IOException(code); });
            failure("Аккаунт создан, но вход не выполнен.\n\n" + m,
                () -> join(n, replace));
        });
    }

    // ─── screen: done ─────────────────────────────────────────────────────
    private void done(String n) {
        clear(); secure(false);
        spacer(24);
        // Big checkmark
        TextView check = makeText("✓", 40, 0xffffffff, true);
        check.setGravity(Gravity.CENTER);
        GradientDrawable chBg = new GradientDrawable();
        chBg.setShape(GradientDrawable.OVAL);
        chBg.setColor(0xff22c55e);
        check.setBackground(chBg);
        LinearLayout.LayoutParams chLp = new LinearLayout.LayoutParams(dp(80), dp(80));
        chLp.gravity = Gravity.CENTER_HORIZONTAL;
        page.addView(check, chLp);
        gap(20);
        TextView title = makeText("Всё готово", 30, text, true);
        title.setGravity(Gravity.CENTER);
        page.addView(title);
        gap(10);
        bodyText("Вы вошли как @" + n + ". Найдите собеседника по нику или добавьте по QR.");
        gap(32);
        btnPrimary("Открыть чаты", this::finish);
    }

    // ─── sponsor helper ───────────────────────────────────────────────────
    private static RegistrationFlow.Sponsor sponsor() {
        String realm = org.paranoid.text.KeyClient.IDENTITY_TEST_REALM;
        String pin   = org.paranoid.text.KeyClient.IDENTITY_TEST_PIN;
        return new RegistrationFlow.Sponsor() {
            public JSONObject prepare() throws Exception {
                return org.paranoid.text.KeyTransport.call(realm, pin, "POST",
                    "/v3/sponsor/prepare",
                    new JSONObject().put("genesis", DevnetRpc.GENESIS).toString(), null);
            }
            public String cosign(String owner, String name, String blockhash,
                                  String ownerSignature) throws Exception {
                return org.paranoid.text.KeyTransport.call(realm, pin, "POST",
                    "/v3/sponsor/register",
                    new JSONObject().put("owner", owner).put("name", name)
                        .put("blockhash", blockhash)
                        .put("owner_signature", ownerSignature).toString(),
                    null).getString("payer_signature");
            }
        };
    }

    // ─── low-level helpers ────────────────────────────────────────────────
    private static long balance(DevnetRpc rpc, String owner) throws Exception {
        return RegistrationFlow.integer(((JSONObject) rpc.call("getBalance",
            new JSONArray().put(owner)
                .put(new JSONObject().put("commitment", "confirmed")))).get("value"));
    }

    private interface Step { String run(DevnetStore s, long ticket) throws Exception; }
    private interface Fail  { void on(long ticket, String code); }

    private void run(Step step) { run(step, null); }
    private void run(Step step, Fail fail) {
        final long ticket = generation.next();
        OWNER.execute(() -> {
            try {
                if (store == null) store = new DevnetStore(getApplicationContext());
                step.run(store, ticket);
            } catch (Throwable e) {
                String code = e.getMessage() == null ? "" : e.getMessage();
                if (e instanceof org.paranoid.text.SyncCycle.Rejected) {
                    org.paranoid.text.SyncCycle.Rejected x = (org.paranoid.text.SyncCycle.Rejected) e;
                    code = "http_" + x.status + (x.code.isEmpty() ? "" : "_" + x.code);
                } else if (e.getClass() != IOException.class)
                    code = e.getClass().getSimpleName() + (code.isEmpty() ? "" : " " + code);
                final String shown = code;
                if (fail != null && e instanceof Exception) {
                    post(ticket, () -> fail.on(ticket, shown)); return;
                }
                String msg = e instanceof LinkageError
                    ? "Раздел недоступен в этой сборке."
                    : DevnetWork.run(() -> { throw e instanceof Exception ? (Exception)e : new IOException(e); });
                post(ticket, () -> failure(msg, this::resume));
            }
        });
    }

    private void post(long ticket, Runnable r) {
        runOnUiThread(() -> {
            if (generation.current(ticket) && !isFinishing() && !isDestroyed()) r.run();
        });
    }
    private void say(long ticket, TextView v, String s) { post(ticket, () -> v.setText(s)); }

    private void failure(String message, Runnable retry) {
        clear(); secure(false);
        heading("Не получилось");
        gap(8);
        TextView m = makeText(message, 15, muted, false);
        m.setLineSpacing(0, 1.4f);
        m.setTextIsSelectable(true);
        page.addView(m);
        gap(28);
        btnPrimary("Повторить", retry);
        gap(12);
        btnSecondary("В начало", this::resume);
    }

    private void busy(String message) {
        clear();
        gap(80);
        ProgressBar p = new ProgressBar(this);
        p.setIndeterminate(true);
        page.addView(p, centred(dp(48), dp(48)));
        gap(16);
        TextView t = makeText(message, 16, muted, false);
        t.setGravity(Gravity.CENTER);
        page.addView(t, full());
    }

    private void secure(boolean on) {
        // Owner decision 2026-10-05: screenshots allowed everywhere, FLAG_SECURE removed.
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_SECURE);
    }
    private void clear() { page.removeAllViews(); }

    /** Linear progress bar (step/total). */
    private void progress(int step, int total) {
        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setPadding(0, 0, 0, dp(28));
        for (int i = 1; i <= total; i++) {
            View seg = new View(this);
            int color = i <= step ? accent : 0x22aaaaaa;
            seg.setBackground(rnd(color, 2));
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(3), 1f);
            if (i < total) lp.rightMargin = dp(4);
            bar.addView(seg, lp);
        }
        page.addView(bar, full());
    }

    // ─── UI atoms ─────────────────────────────────────────────────────────
    private void heading(String s) {
        TextView v = makeText(s, 30, text, true);
        v.setLineSpacing(0, 1.1f);
        page.addView(v);
    }
    private void bodyText(String s) {
        TextView v = makeText(s, 16, muted, false);
        v.setLineSpacing(0, 1.4f);
        v.setTextIsSelectable(true);
        page.addView(v);
    }
    private void gap(int h) {
        page.addView(new View(this), new LinearLayout.LayoutParams(1, dp(h)));
    }
    private void spacer(int h) {
        page.addView(new View(this), new LinearLayout.LayoutParams(-1, dp(h)));
    }
    private View spacerH(int w) {
        View v = new View(this); v.setLayoutParams(new LinearLayout.LayoutParams(dp(w), 1));
        return v;
    }
    private TextView makeText(String s, int size, int color, boolean bold) {
        TextView v = new TextView(this);
        v.setText(s); v.setTextSize(size); v.setTextColor(color);
        if (bold) v.setTypeface(Typeface.DEFAULT_BOLD);
        return v;
    }
    private TextView chip(String label) {
        TextView c = new TextView(this);
        c.setText(label);
        c.setTextSize(12);
        c.setTextColor(muted);
        c.setPadding(dp(10), dp(5), dp(10), dp(5));
        c.setBackground(rnd(surface, 20));
        return c;
    }
    private LinearLayout boxPanel(int bg, int borderColor) {
        LinearLayout b = new LinearLayout(this);
        b.setOrientation(LinearLayout.VERTICAL);
        b.setPadding(dp(14), dp(12), dp(14), dp(12));
        GradientDrawable d = new GradientDrawable();
        d.setColor(bg);
        d.setCornerRadius(dp(12));
        d.setStroke(dp(1), borderColor);
        b.setBackground(d);
        return b;
    }
    private void serverCard(String icon, String head, String sub, boolean enabled, Runnable r) {
        LinearLayout c = new LinearLayout(this);
        c.setOrientation(LinearLayout.HORIZONTAL);
        c.setGravity(Gravity.CENTER_VERTICAL);
        c.setPadding(dp(16), dp(16), dp(16), dp(16));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(surface);
        bg.setCornerRadius(dp(16));
        if (enabled) {
            bg.setStroke(dp(2), accent);
        }
        c.setBackground(bg);
        TextView ic = makeText(icon, 24, text, false);
        ic.setPadding(0, 0, dp(14), 0);
        c.addView(ic);
        LinearLayout txt = new LinearLayout(this);
        txt.setOrientation(LinearLayout.VERTICAL);
        txt.addView(makeText(head, 16, text, true));
        TextView sv = makeText(sub, 13, muted, false);
        sv.setPadding(0, dp(3), 0, 0);
        txt.addView(sv);
        c.addView(txt, new LinearLayout.LayoutParams(0, -2, 1f));
        if (!enabled) {
            TextView soon = makeText("Скоро", 12, muted, false);
            soon.setPadding(dp(10), dp(4), dp(10), dp(4));
            soon.setBackground(rnd(0x22aaaaaa, 10));
            c.addView(soon);
        }
        c.setAlpha(enabled ? 1f : .55f);
        if (enabled && r != null) { c.setClickable(true); c.setOnClickListener(v -> r.run()); }
        page.addView(c, full());
    }
    private void btnPrimary(String s, Runnable r) {
        Button b = new Button(this);
        b.setText(s); b.setAllCaps(false); b.setTextSize(17);
        b.setTextColor(0xffffffff); b.setBackground(rnd(accent, 14));
        b.setMinHeight(dp(54)); b.setOnClickListener(v -> r.run());
        page.addView(b, full());
    }
    private void btnSecondary(String s, Runnable r) {
        Button b = new Button(this);
        b.setText(s); b.setAllCaps(false); b.setTextSize(16);
        b.setTextColor(accent); b.setBackground(rnd(surface, 14));
        b.setMinHeight(dp(50)); b.setOnClickListener(v -> r.run());
        page.addView(b, full());
    }
    private GradientDrawable rnd(int color, int radiusDp) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(color); g.setCornerRadius(dp(radiusDp));
        return g;
    }
    private LinearLayout.LayoutParams full() {
        return new LinearLayout.LayoutParams(-1, -2);
    }
    private LinearLayout.LayoutParams fullW(int h) {
        return new LinearLayout.LayoutParams(-1, h);
    }
    private LinearLayout.LayoutParams centred(int w, int h) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(w, h);
        lp.gravity = Gravity.CENTER_HORIZONTAL;
        return lp;
    }
    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}
