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
