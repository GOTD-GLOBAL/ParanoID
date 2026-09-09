package org.paranoid.text;

import org.json.JSONObject;

/** Product state shown by the native UI; trust never gates incoming replies. */
public final class DialogPolicy {
    private DialogPolicy(){}
    public static String trustLabel(JSONObject dialog) {
        return dialog!=null && dialog.optString("trust").equals("out_of_band_verified")
            ?"Личность проверена":"Личность не проверена";
    }
    public static boolean canReply(JSONObject dialog,boolean active,boolean broken,boolean sending) {
        return dialog!=null && !dialog.optString("account").isEmpty() && active && !broken && !sending && !dialog.optBoolean("blocked");
    }
}
