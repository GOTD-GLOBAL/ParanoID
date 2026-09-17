package org.paranoid.text;

import android.content.Context;
import android.content.SharedPreferences;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * The calls this phone has had, and where they stand in a conversation.
 *
 * The call-shaped sibling of {@link ContactNames}: app-private preferences keyed by account, never
 * part of the encrypted snapshot, never sent to the peer or the server. The core writes no call
 * history and no receipt for a call (docs/protocol/voice-v1.md:27-31) and that is unchanged; this is
 * bookkeeping the device does for itself out of a terminal transition it already went through.
 *
 * Each row is {@code {id, kind, video, duration_seconds, after_message_id}}. The identifier is the
 * call identifier, so one call leaves one row however many times a view is republished — the same
 * idempotence {@code CallTones} keeps for its transitions.
 */
public final class CallLog {
    private static final String PREFS="paranoid-call-log-v1",REVISION="revision";
    /** Rows kept per conversation. The bound is on this local log alone; the message history has none. */
    public static final int PER_ACCOUNT_LIMIT=500;
    private CallLog(){}

    private static SharedPreferences prefs(Context context){
        return context.getSharedPreferences(PREFS,Context.MODE_PRIVATE);
    }

    /** This conversation's rows, oldest first; never null. */
    public static JSONArray records(Context context,String account){
        if(account==null||account.isEmpty())return new JSONArray();
        String stored=prefs(context).getString(account,"");
        if(stored.isEmpty())return new JSONArray();
        try{return new JSONArray(stored);}catch(Exception unreadable){return new JSONArray();}
    }

    /** Records one finished call. Returns false when the row was already there or is unusable. */
    public static boolean record(Context context,String account,JSONObject row){
        if(account==null||account.isEmpty()||row==null||row.optString("id","").isEmpty())return false;
        JSONArray rows=records(context,account);
        for(int n=0;n<rows.length();n++){
            JSONObject existing=rows.optJSONObject(n);
            if(existing!=null&&existing.optString("id").equals(row.optString("id")))return false;
        }
        rows.put(row);
        while(rows.length()>PER_ACCOUNT_LIMIT)rows.remove(0);
        SharedPreferences preferences=prefs(context);
        preferences.edit().putString(account,rows.toString())
            .putLong(REVISION,preferences.getLong(REVISION,0)+1).apply();
        return true;
    }

    /** Forgets one conversation's calls. */
    public static void forget(Context context,String account){
        if(account==null||account.isEmpty())return;
        SharedPreferences preferences=prefs(context);
        if(!preferences.contains(account))return;
        preferences.edit().remove(account).putLong(REVISION,preferences.getLong(REVISION,0)+1).apply();
    }

    /**
     * A counter that moves on every write. The chat and the list re-render only when their signature
     * changes (MainActivity.renderHistory, renderLists), and a call changes no message, so without
     * this a new row would not appear until an unrelated message did.
     */
    public static long revision(Context context){return prefs(context).getLong(REVISION,0);}
}
