package org.paranoid.text;

import android.content.Context;
import org.json.JSONObject;

/** One presentation-only dismissal bit per installation. No peer identifiers, wire or snapshot writes. */
public final class ReceiptHint {
    private static final String PREFS="paranoid-receipt-hint-v1",DISMISSED="dismissed";
    private ReceiptHint(){}
    public static boolean isPending(Context context){
        return !context.getSharedPreferences(PREFS,Context.MODE_PRIVATE).getBoolean(DISMISSED,false);
    }
    public static boolean shouldShow(Context context,JSONObject dialog){
        return isPending(context)&&MessagePresentation.receiptHintEarned(dialog);
    }
    public static void dismiss(Context context){
        if(isPending(context))context.getSharedPreferences(PREFS,Context.MODE_PRIVATE)
            .edit().putBoolean(DISMISSED,true).apply();
    }
}
