import java.util.Calendar;
import java.util.TimeZone;
import org.paranoid.text.MessagePresentation;

/** REQ-CLIENT-004: when a message happened, as the screens read it — and nothing invented. */
public final class MessageTimeSmoke {
    static void check(boolean yes,String why){if(!yes)throw new AssertionError(why);}
    static long instant(int year,int month,int day,int hour,int minute){
        Calendar value=Calendar.getInstance();value.clear();
        value.set(year,month-1,day,hour,minute,0);return value.getTimeInMillis();
    }
    public static void main(String[] args){
        // The rule is the phone's own zone; the test pins one so the result is the same everywhere.
        TimeZone.setDefault(TimeZone.getTimeZone("Europe/Moscow"));
        check(MessagePresentation.time(instant(2026,9,17,14,32)).equals("14:32"),"the time under a bubble");
        check(MessagePresentation.time(instant(2026,9,17,9,5)).equals("09:05"),"a single-digit hour is padded");
        check(MessagePresentation.time(instant(2026,9,17,0,0)).equals("00:00"),"midnight reads as midnight");

        check(MessagePresentation.time(0).isEmpty(),"a message without a time is shown without one");
        check(MessagePresentation.listTime(0,instant(2026,9,17,12,0)).isEmpty(),"a row without a time says nothing");
        check(MessagePresentation.daySeparator(0,instant(2026,9,17,12,0)).isEmpty(),"no separator for an unknown time");
        check(!MessagePresentation.startsNewDay(0,instant(2026,9,16,12,0)),"an unknown time opens no day");

        long morning=instant(2026,9,17,9,0),evening=instant(2026,9,17,23,59),next=instant(2026,9,18,0,1);
        check(MessagePresentation.startsNewDay(morning,0),"the first timed message opens a day of its own");
        check(!MessagePresentation.startsNewDay(evening,morning),"the same day opens nothing");
        check(MessagePresentation.startsNewDay(next,evening),"one minute past midnight is a different day");

        long today=instant(2026,9,17,14,0);
        check(MessagePresentation.daySeparator(today,today).equals("Сегодня"),"today names itself");
        check(MessagePresentation.daySeparator(instant(2026,9,16,23,0),today).equals("Вчера"),"yesterday names itself");
        check(MessagePresentation.daySeparator(instant(2026,9,12,8,0),today).equals("12 сентября"),"an older day is named");
        check(MessagePresentation.daySeparator(instant(2025,12,31,8,0),today).equals("31 декабря 2025"),"another year is named");

        long now=instant(2026,9,17,16,6);
        check(MessagePresentation.listTime(instant(2026,9,17,10,5),now).equals("10:05"),"a row shows today's time");
        check(MessagePresentation.listTime(instant(2026,9,16,21,40),now).equals("Вчера"),"a row says yesterday");
        check(MessagePresentation.listTime(instant(2026,9,12,21,40),now).equals("12.09"),"a row shows an older date");
        check(MessagePresentation.listTime(instant(2025,9,12,21,40),now).equals("12.09.2025"),"a row names another year");
        System.out.println("PASS: message time, day separators and conversation-row dates");
    }
}
