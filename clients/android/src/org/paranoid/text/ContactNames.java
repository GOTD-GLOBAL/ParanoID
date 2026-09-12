package org.paranoid.text;

import android.content.Context;
import android.content.SharedPreferences;

/**
 * Local display names for contacts (owner request 2026-09-12). Purely presentational: stored in
 * app-private preferences keyed by account id, never sent to the peer or server, never part of the
 * encrypted snapshot/identity boundary (the state file is untouched). Absent name = default title.
 */
public final class ContactNames {
    private static final String PREFS="paranoid-contact-names-v1";
    public static final int MAX_LENGTH=40;
    private ContactNames(){}
    public static String get(Context context,String account){
        if(account==null||account.isEmpty())return "";
        return context.getSharedPreferences(PREFS,Context.MODE_PRIVATE).getString(account,"");
    }
    /** Empty or blank clears the custom name. Returns the stored value. */
    public static String set(Context context,String account,String name){
        String clean=normalize(name);
        SharedPreferences.Editor edit=context.getSharedPreferences(PREFS,Context.MODE_PRIVATE).edit();
        if(clean.isEmpty())edit.remove(account);else edit.putString(account,clean);
        edit.apply();return clean;
    }
    public static String title(Context context,String account){
        String custom=get(context,account);
        return custom.isEmpty()?MessagePresentation.title(account):custom;
    }
    /** Single line, trimmed, bounded; control characters removed. */
    public static String normalize(String name){
        if(name==null)return "";
        StringBuilder out=new StringBuilder();
        for(int i=0;i<name.length();){
            int cp=name.codePointAt(i);i+=Character.charCount(cp);
            if(Character.isWhitespace(cp)||Character.isSpaceChar(cp))cp=' ';
            else if(Character.isISOControl(cp)||Character.getType(cp)==Character.FORMAT)continue;
            out.appendCodePoint(cp);
        }
        String line=out.toString().replaceAll(" {2,}"," ").trim();
        if(line.codePointCount(0,line.length())>MAX_LENGTH)line=line.substring(0,line.offsetByCodePoints(0,MAX_LENGTH)).trim();
        return line;
    }
}
