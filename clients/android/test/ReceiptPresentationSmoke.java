import org.json.JSONArray;
import org.json.JSONObject;
import org.paranoid.text.MessagePresentation;

public final class ReceiptPresentationSmoke {
    static void check(boolean value,String message){if(!value)throw new AssertionError(message);}
    static JSONObject message(String author,boolean accepted,boolean delivered){
        return new JSONObject().put("author",author).put("accepted",accepted).put("delivered",delivered);
    }
    static JSONObject dialog(JSONObject... messages){
        JSONArray rows=new JSONArray();for(JSONObject m:messages)rows.put(m);
        return new JSONObject().put("own","me").put("messages",rows);
    }
    public static void main(String[] args){
        check("queued".equals(MessagePresentation.mark(message("me",false,false))),"queued shape");
        check("stored".equals(MessagePresentation.mark(message("me",true,false))),"stored shape");
        check("delivered".equals(MessagePresentation.mark(message("me",true,true))),"delivered shape");
        check("В очереди".equals(MessagePresentation.delivery(message("me",false,false))),"queued label unchanged");
        check("Сохранено сервером".equals(MessagePresentation.delivery(message("me",true,false))),"stored label unchanged");
        check("Доставлено".equals(MessagePresentation.delivery(message("me",true,true))),"delivered label unchanged");
        check(!MessagePresentation.receiptHintEarned(null),"no dialog");
        check(!MessagePresentation.receiptHintEarned(new JSONObject()),"no own identity");
        check(!MessagePresentation.receiptHintEarned(dialog()),"empty chat");
        check(!MessagePresentation.receiptHintEarned(dialog(message("peer",true,true))),"incoming delivery is not own delivery");
        check(!MessagePresentation.receiptHintEarned(dialog(message("me",true,false))),"server acceptance is not delivery");
        check(!MessagePresentation.receiptHintEarned(dialog(message("me",false,false))),"queue is not delivery");
        JSONObject earned=dialog(message("me",true,true),message("peer",true,true),message("me",false,false));
        String before=earned.toString();
        check(MessagePresentation.receiptHintEarned(earned),"any own delivered message earns hint, not only latest");
        check(before.equals(earned.toString()),"rendering never mutates committed view");
        check(!MessagePresentation.receiptHintEarned(new JSONObject().put("own","").put("messages",new JSONArray().put(message("",true,true)))),"missing own ID cannot earn hint");
        System.out.println("PASS receipt states/labels, own-delivery hint eligibility, null/empty/input preservation");
    }
}
