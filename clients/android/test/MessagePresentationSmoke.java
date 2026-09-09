import org.json.JSONObject;
import org.paranoid.text.MessagePresentation;

/** REQ-MSG-003/005: displayed receipts, Unicode limits and in-flight draft safety. */
public final class MessagePresentationSmoke {
    private static void require(boolean value,String message){if(!value)throw new AssertionError(message);}
    public static void main(String[] args)throws Exception{
        JSONObject queued=new JSONObject().put("accepted",false).put("delivered",false);
        require(MessagePresentation.delivery(queued).equals("В очереди"),"unsent text must not look delivered");
        require(MessagePresentation.delivery(new JSONObject().put("accepted",true)).equals("Сохранено сервером"),"server acceptance is one check");
        require(MessagePresentation.delivery(new JSONObject().put("accepted",true).put("delivered",true)).equals("Доставлено"),"peer receipt is delivery, never reading");
        require(!MessagePresentation.delivery(queued).contains("Прочитано"),"no read claim");
        require(MessagePresentation.canSend("Привет"),"Cyrillic text supported");
        require(!MessagePresentation.canSend("   \n"),"blank sends disabled");
        require(MessagePresentation.canSend(repeat("🙂",512)),"2048 UTF-8 bytes accepted");
        require(!MessagePresentation.canSend(repeat("🙂",513)),"UTF-8 quota must not use Java char count");
        require(MessagePresentation.preview("a\nb\t c").equals("a b c"),"list preview has one line");
        String account="0123456789abcdef0123456789abcdef";
        require(MessagePresentation.title(account).equals("Контакт 012345"),"unknown sender has a readable stable name");
        require(MessagePresentation.shortId(account).equals("01234567…89abcdef"),"full IDs do not overwhelm list");
        MessagePresentation.Drafts drafts=new MessagePresentation.Drafts();
        drafts.update("a","first");MessagePresentation.Ticket sent=drafts.ticket("a");
        drafts.update("b","other conversation");drafts.committed(sent);
        require(drafts.text("a").isEmpty()&&drafts.text("b").equals("other conversation"),"commit clears only original conversation");
        drafts.update("a","same");sent=drafts.ticket("a");drafts.update("a","edited");drafts.update("a","same");drafts.committed(sent);
        require(drafts.text("a").equals("same"),"late commit must retain a newly edited draft even when text matches");
        sent=drafts.ticket("a");require(drafts.text("a").equals("same"),"failed send leaves draft intact");
        require(sent.text.equals("same"),"ticket freezes exact submitted text");
        drafts.started(sent);require(drafts.sending(),"configuration recreation shares pending draft state");
        drafts.finished(sent,false);require(!drafts.sending()&&drafts.text("a").equals("same"),"failed completion unlocks sending without deleting draft");
        drafts.started(sent);drafts.finished(sent,true);require(!drafts.sending()&&drafts.text("a").isEmpty(),"successful completion updates the shared draft model");
        System.out.println("PASS: receipt semantics, 2048-byte Unicode limit, readable unknown sender, in-flight per-chat draft safety");
    }
    private static String repeat(String text,int n){StringBuilder out=new StringBuilder();while(n-->0)out.append(text);return out.toString();}
}
