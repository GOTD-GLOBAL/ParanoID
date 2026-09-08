package org.paranoid.bootstrap;
import android.app.Activity;
import android.os.Bundle;
import android.os.Build;
import android.widget.TextView;
public final class MainActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        TextView screen = new TextView(this);
        screen.setPadding(32, 96, 32, 32);
        screen.setTextSize(20);
        screen.setText("ParanoID — проверка установки\n\n"
            + "Это диагностическая сборка, не мессенджер.\n"
            + "Сеть, аккаунты и E2EE не подключены.\n"
            + "Никакие сообщения не отправляются.\n\n"
            + "Устройство: " + Build.MANUFACTURER + " " + Build.MODEL
            + "\nAndroid: " + Build.VERSION.RELEASE + " (API " + Build.VERSION.SDK_INT + ")");
        setContentView(screen);
    }
}
