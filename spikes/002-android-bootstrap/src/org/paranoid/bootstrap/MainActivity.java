package org.paranoid.bootstrap;
import android.app.Activity;
import android.os.Bundle;
import android.os.Build;
import android.widget.TextView;

public final class MainActivity extends Activity {
    private static native int nativeProbe();
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        final TextView screen = new TextView(this);
        screen.setPadding(32, 96, 32, 32);
        screen.setTextSize(18);
        screen.setText("ParanoID — Android crypto test\n\n"
            + "Локальные тестовые участники. Не мессенджер.\n"
            + "Сети и постоянных аккаунтов нет.\n\n"
            + Build.MANUFACTURER + " " + Build.MODEL
            + " / Android " + Build.VERSION.RELEASE
            + "\nABI: " + Build.SUPPORTED_ABIS[0] + "\n\nПроверка выполняется…");
        setContentView(screen);
        new Thread(new Runnable() {
            @Override public void run() {
                String result;
                try {
                    System.loadLibrary("paranoid_android_probe");
                    int code = nativeProbe();
                    result = code == 0 ? "PASS: Rust/vodozemac загружен.\nОбмен, подмена и повтор проверены."
                        : "FAIL: проверка криптомодуля, код " + code;
                } catch (UnsatisfiedLinkError | SecurityException error) {
                    result = "FAIL: не удалось загрузить ARM64 библиотеку (" + error.getClass().getSimpleName() + ")";
                }
                final String message = result;
                runOnUiThread(new Runnable() {
                    @Override public void run() {
                        if (!isDestroyed()) screen.append("\n\n" + message);
                    }
                });
            }
        }, "crypto-probe").start();
    }
}
