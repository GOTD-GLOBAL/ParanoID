import org.paranoid.text.ContactNames;

/** Host JVM checks for the local-only contact name normalizer (no Android Context needed). */
public final class ContactNamesSmoke {
    static void check(boolean ok,String m){if(!ok)throw new AssertionError(m);}
    public static void main(String[] a){
        check(ContactNames.normalize(null).isEmpty()&&ContactNames.normalize("   ").isEmpty(),"blank clears");
        check(ContactNames.normalize("  Серёга  ").equals("Серёга"),"trim");
        check(ContactNames.normalize("Мама\nпапа\tдом").equals("Мама папа дом"),"single line");
        check(ContactNames.normalize("a\u0000b\u200Ec\u202Ed").equals("abcd"),"control/format chars removed");
        check(ContactNames.normalize("x   y").equals("x y"),"collapse spaces");
        String longName=new String(new char[100]).replace('\0','ж');
        check(ContactNames.normalize(longName).codePointCount(0,ContactNames.normalize(longName).length())==ContactNames.MAX_LENGTH,"bounded to MAX_LENGTH code points");
        StringBuilder e=new StringBuilder();for(int i=0;i<50;i++)e.append("😀");String emoji=e.toString();
        check(ContactNames.normalize(emoji).codePointCount(0,ContactNames.normalize(emoji).length())==ContactNames.MAX_LENGTH,"surrogate pairs not split");
        System.out.println("ContactNamesSmoke PASS");
    }
}
