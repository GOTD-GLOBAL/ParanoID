import org.json.JSONArray;
import org.json.JSONObject;
import org.paranoid.text.MessagePresentation;

/** REQ-CALL-002/004: what a finished call means, how it reads, and where it stands in the chat. */
public final class CallLogSmoke {
    static void check(boolean yes,String why){if(!yes)throw new AssertionError(why);}
    public static void main(String[] args)throws Exception{
        // The same wire reason means different things on the two sides of one call.
        check(MessagePresentation.callKind(false,false,"reject").equals("declined"),"a refusal here is «вы отклонили»");
        check(MessagePresentation.callKind(true,false,"reject").equals("rejected"),"the same refusal there is «собеседник отклонил»");
        check(MessagePresentation.callKind(true,false,"cancel").equals("cancelled"),"a caller giving up cancelled its own call");
        check(MessagePresentation.callKind(false,false,"cancel").equals("missed"),"a caller giving up is a missed call for the callee");
        check(MessagePresentation.callKind(true,false,"timeout").equals("unanswered"),"an unanswered outgoing ring is not a missed call");
        check(MessagePresentation.callKind(false,false,"timeout").equals("missed"),"an unanswered incoming ring is a missed call");
        check(MessagePresentation.callKind(true,false,"busy").equals("busy"),"a busy peer is busy, not missed");
        check(MessagePresentation.callKind(false,false,"busy").equals("missed"),"a call refused while busy is still missed here");
        check(MessagePresentation.callKind(true,false,"failed").equals("failed"),"a call that never connected failed");
        check(MessagePresentation.callKind(false,false,"unavailable").equals("failed"),"an unavailable peer failed");
        for(String reason:new String[]{"hangup","reject","cancel","busy","timeout","failed","unavailable"}){
            check(MessagePresentation.callKind(true,true,reason).equals("outgoing"),"an answered outgoing call stays answered");
            check(MessagePresentation.callKind(false,true,reason).equals("incoming"),"an answered incoming call stays answered");
        }
        check(MessagePresentation.callMissed("missed")&&!MessagePresentation.callMissed("unanswered"),"only a missed inbound ring raises a notice");

        // The words, and the duration only for a call that actually connected.
        check(MessagePresentation.callTitle("missed",false).equals("Пропущенный звонок"),"missed row names itself");
        check(MessagePresentation.callTitle("missed",true).equals("Пропущенный видеозвонок"),"video missed row names itself");
        check(MessagePresentation.callLine("outgoing",false,192).equals("Исходящий звонок · 3:12"),"answered row carries its duration");
        check(MessagePresentation.callLine("unanswered",false,0).equals("Нет ответа"),"an unanswered row carries no duration");
        check(MessagePresentation.callDuration(59).equals("0:59")&&MessagePresentation.callDuration(60).equals("1:00"),"duration is minutes and seconds");
        check(!MessagePresentation.callTitle("incoming",false).contains("рочитано"),"a call row claims nothing about reading");

        // Where a row stands, in a history the core stores no time for.
        JSONArray messages=new JSONArray().put(message("m1")).put(message("m2"));
        JSONArray calls=new JSONArray().put(call("c1","missed","m1")).put(call("c2","outgoing","m2"));
        check(ids(MessagePresentation.chatRows(messages,calls)).equals("m1,c1,m2,c2"),"each call stands after the message it followed");
        check(ids(MessagePresentation.chatRows(messages,new JSONArray())).equals("m1,m2"),"a conversation without calls is its messages unchanged");
        check(ids(MessagePresentation.chatRows(messages,new JSONArray().put(call("c1","missed","")))).equals("c1,m1,m2"),"a call before any message opens the chat");
        check(ids(MessagePresentation.chatRows(messages,new JSONArray().put(call("c1","missed","lost")))).equals("m1,m2,c1"),"a call whose anchor is gone is not lost");
        System.out.println("PASS: call outcomes, their wording and their place in the conversation");
    }
    private static JSONObject message(String id){return new JSONObject().put("id",id).put("text","t");}
    private static JSONObject call(String id,String kind,String anchor){
        return new JSONObject().put("id",id).put("kind",kind).put("video",false)
            .put("duration_seconds",0).put("after_message_id",anchor);
    }
    private static String ids(JSONArray rows){
        StringBuilder out=new StringBuilder();
        for(int n=0;n<rows.length();n++){
            if(n>0)out.append(',');
            out.append(rows.optJSONObject(n).optJSONObject("value").optString("id"));
        }
        return out.toString();
    }
}
