package org.paranoid.text;

import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import org.json.JSONObject;

/** UI-only formatting and in-memory drafts. No keys, wire or snapshot mutations. */
public final class MessagePresentation {
    private MessagePresentation(){}
    public static String title(String account){return "Контакт "+account.substring(0,Math.min(6,account.length()));}
    public static String shortId(String account){return account.length()>16?account.substring(0,8)+"…"+account.substring(account.length()-8):account;}
    public static String preview(String text){
        String line=text.replaceAll("\\s+"," ").trim();
        int points=line.codePointCount(0,line.length());
        return points>80?line.substring(0,line.offsetByCodePoints(0,80))+"…":line;
    }
    public static int byteCount(String text){return text.getBytes(StandardCharsets.UTF_8).length;}
    public static boolean canSend(String text){return !text.trim().isEmpty()&&byteCount(text)<=2048;}
    public static String delivery(JSONObject message){
        return message.optBoolean("delivered")?"Доставлено":message.optBoolean("accepted")?"Сохранено сервером":"В очереди";
    }
    /** The mark drawn under an own bubble: "queued", "stored" or "delivered" (iOS MessagePresentation.Mark). */
    public static String mark(JSONObject message){
        return message.optBoolean("delivered")?"delivered":message.optBoolean("accepted")?"stored":"queued";
    }

    // --- when a message happened (iOS MessagePresentation) ----------------

    /** The months as a date is read aloud in Russian, so a separator never depends on the locale. */
    static final String[] MONTHS_GENITIVE={"января","февраля","марта","апреля","мая","июня",
        "июля","августа","сентября","октября","ноября","декабря"};

    /**
     * `14:32` — the time under a bubble, in this phone's own time zone. An entry written by a build
     * that kept no time answers the empty string and the screens draw nothing: a message whose time
     * is unknown is shown without one rather than with a guess (REQ-CLIENT-004).
     */
    public static String time(long milliseconds){
        if(milliseconds<=0)return "";
        java.util.Calendar when=calendar(milliseconds);
        return String.format(java.util.Locale.ROOT,"%02d:%02d",
            when.get(java.util.Calendar.HOUR_OF_DAY),when.get(java.util.Calendar.MINUTE));
    }
    /** Whether a message begins a day the one before it did not. An unknown time never begins one. */
    public static boolean startsNewDay(long milliseconds,long previous){
        if(milliseconds<=0)return false;
        if(previous<=0)return true;
        return !sameDay(calendar(previous),calendar(milliseconds));
    }
    /** The pill between two days: «Сегодня», «Вчера», «15 сентября», with the year once it differs. */
    public static String daySeparator(long milliseconds,long now){
        if(milliseconds<=0)return "";
        java.util.Calendar when=calendar(milliseconds),today=calendar(now);
        if(sameDay(when,today))return "Сегодня";
        java.util.Calendar yesterday=calendar(now);yesterday.add(java.util.Calendar.DAY_OF_YEAR,-1);
        if(sameDay(when,yesterday))return "Вчера";
        String date=when.get(java.util.Calendar.DAY_OF_MONTH)+" "+MONTHS_GENITIVE[when.get(java.util.Calendar.MONTH)];
        return when.get(java.util.Calendar.YEAR)==today.get(java.util.Calendar.YEAR)?date:date+" "+when.get(java.util.Calendar.YEAR);
    }
    /** What a conversation row says: the time today, «Вчера» yesterday, the date before that. */
    public static String listTime(long milliseconds,long now){
        if(milliseconds<=0)return "";
        java.util.Calendar when=calendar(milliseconds),today=calendar(now);
        if(sameDay(when,today))return time(milliseconds);
        java.util.Calendar yesterday=calendar(now);yesterday.add(java.util.Calendar.DAY_OF_YEAR,-1);
        if(sameDay(when,yesterday))return "Вчера";
        String stamp=String.format(java.util.Locale.ROOT,"%02d.%02d",
            when.get(java.util.Calendar.DAY_OF_MONTH),when.get(java.util.Calendar.MONTH)+1);
        return when.get(java.util.Calendar.YEAR)==today.get(java.util.Calendar.YEAR)?stamp:stamp+"."+when.get(java.util.Calendar.YEAR);
    }
    private static java.util.Calendar calendar(long milliseconds){
        java.util.Calendar value=java.util.Calendar.getInstance();value.setTimeInMillis(milliseconds);return value;
    }
    private static boolean sameDay(java.util.Calendar a,java.util.Calendar b){
        return a.get(java.util.Calendar.YEAR)==b.get(java.util.Calendar.YEAR)
            &&a.get(java.util.Calendar.DAY_OF_YEAR)==b.get(java.util.Calendar.DAY_OF_YEAR);
    }

    // --- what one finished call leaves in the chat (iOS CallRecord) --------

    /**
     * The outcome of one call from the terminal facts this device saw. The seven wire reasons are
     * the closed set of voice-v1.md:53, and the same reason means different things on the two sides:
     * `reject` is "you declined" for the phone that pressed it and "they declined" for the other,
     * and a caller giving up is a missed call for the callee. No call row is ever sent or stored
     * outside this phone.
     */
    public static String callKind(boolean outgoing,boolean connected,String reason){
        if(connected)return outgoing?"outgoing":"incoming";
        if(reason==null)return "failed";
        switch(reason){
            case "reject": return outgoing?"rejected":"declined";
            case "cancel": case "hangup": return outgoing?"cancelled":"missed";
            case "timeout": return outgoing?"unanswered":"missed";
            case "busy": return outgoing?"busy":"missed";
            case "failed": case "unavailable": return "failed";
            default: return "failed";
        }
    }
    /** The one outcome a missed-call notice is raised for. */
    public static boolean callMissed(String kind){return "missed".equals(kind);}
    /** What the row says happened. */
    public static String callTitle(String kind,boolean video){
        switch(kind){
            case "outgoing": return video?"Исходящий видеозвонок":"Исходящий звонок";
            case "incoming": return video?"Входящий видеозвонок":"Входящий звонок";
            case "missed": return video?"Пропущенный видеозвонок":"Пропущенный звонок";
            case "declined": return "Вы отклонили звонок";
            case "rejected": return "Собеседник отклонил звонок";
            case "cancelled": return "Вызов отменён";
            case "unanswered": return "Нет ответа";
            case "busy": return "Собеседник занят";
            default: return "Связь не установилась";
        }
    }
    /** `3:12`, the way the call screen counts. */
    public static String callDuration(long seconds){
        return String.format(java.util.Locale.ROOT,"%d:%02d",seconds/60,seconds%60);
    }
    /** The whole line: what happened and, for an answered call, how long it lasted. */
    public static String callLine(String kind,boolean video,long seconds){
        String title=callTitle(kind,video);
        return seconds>0?title+" · "+callDuration(seconds):title;
    }
    /** The action offered on a missed row. */
    public static String callBack(){return "Перезвонить";}

    /**
     * The conversation as the chat draws it: the core's messages in their own order, with each call
     * standing after the message it followed. The core keeps no time for a message, so a call is
     * anchored to the last message that existed when it ended rather than sorted by a clock this
     * client would have to invent. A call recorded before any message opens the chat; a call whose
     * anchor is gone stands at the end rather than disappearing.
     */
    public static org.json.JSONArray chatRows(org.json.JSONArray messages,org.json.JSONArray calls){
        org.json.JSONArray rows=new org.json.JSONArray();
        if(calls==null||calls.length()==0){
            for(int n=0;n<(messages==null?0:messages.length());n++)rows.put(row("message",messages.optJSONObject(n)));
            return rows;
        }
        java.util.Set<String> known=new java.util.HashSet<>();
        for(int n=0;n<(messages==null?0:messages.length());n++){
            JSONObject message=messages.optJSONObject(n);
            if(message!=null)known.add(message.optString("id"));
        }
        java.util.Map<String,java.util.List<JSONObject>> byAnchor=new java.util.HashMap<>();
        java.util.List<JSONObject> leading=new java.util.ArrayList<>(),trailing=new java.util.ArrayList<>();
        for(int n=0;n<calls.length();n++){
            JSONObject call=calls.optJSONObject(n);if(call==null)continue;
            String anchor=call.optString("after_message_id","");
            if(anchor.isEmpty())leading.add(call);
            else if(known.contains(anchor)){
                java.util.List<JSONObject> list=byAnchor.get(anchor);
                if(list==null){list=new java.util.ArrayList<>();byAnchor.put(anchor,list);}
                list.add(call);
            } else trailing.add(call);
        }
        for(JSONObject call:leading)rows.put(row("call",call));
        for(int n=0;n<(messages==null?0:messages.length());n++){
            JSONObject message=messages.optJSONObject(n);if(message==null)continue;
            rows.put(row("message",message));
            java.util.List<JSONObject> after=byAnchor.get(message.optString("id"));
            if(after!=null)for(JSONObject call:after)rows.put(row("call",call));
        }
        for(JSONObject call:trailing)rows.put(row("call",call));
        return rows;
    }
    private static JSONObject row(String type,JSONObject value){
        try{return new JSONObject().put("type",type).put("value",value==null?new JSONObject():value);}
        catch(org.json.JSONException impossible){throw new IllegalStateException("chat row",impossible);}
    }
    public static final class Ticket {
        public final String account,text;
        private final long revision;
        private Ticket(String account,String text,long revision){this.account=account;this.text=text;this.revision=revision;}
    }
    public static final class Drafts {
        private final Map<String,String> text=new HashMap<>();
        private final Map<String,Long> revisions=new HashMap<>();
        private long revision=0;
        private Ticket pending;
        public boolean sending(){return pending!=null;}
        public void started(Ticket ticket){if(pending!=null)throw new IllegalStateException("send already pending");pending=ticket;}
        public void finished(Ticket ticket,boolean committed){if(pending!=ticket)return;if(committed)committed(ticket);pending=null;}
        public String text(String account){String value=text.get(account);return value==null?"":value;}
        public void update(String account,String value){
            if(account.isEmpty()||text(account).equals(value))return;
            text.put(account,value);revisions.put(account,++revision);
        }
        public Ticket ticket(String account){return new Ticket(account,text(account),revisions.containsKey(account)?revisions.get(account):0);}
        public void committed(Ticket ticket){
            long current=revisions.containsKey(ticket.account)?revisions.get(ticket.account):0;
            if(current==ticket.revision){text.remove(ticket.account);revisions.put(ticket.account,++revision);}
        }
    }
}
