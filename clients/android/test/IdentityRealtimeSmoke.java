import org.paranoid.text.*;
import org.paranoid.devnet.IdentityLogin;
import org.json.*;
import java.util.*;
import java.util.concurrent.*;

/** RFC-0027: the real background loop on an identity-v3 server waits for the ID login
 * (never attempts v2 registration), then delivers E2EE text by itself after login.
 * args: realm pin entropyA nameA entropyB nameB */
public final class IdentityRealtimeSmoke {
    static final class Phone {
        final ExecutorService owner=Executors.newSingleThreadExecutor();
        SelfServiceClient client;RealtimeLoop loop;
        final List<String> statuses=Collections.synchronizedList(new ArrayList<>());
        final Map<String,String> saved=new ConcurrentHashMap<>();
        <T> T on(Callable<T> c)throws Exception{return owner.submit(c).get(60,TimeUnit.SECONDS);}
        Phone(String realm,String pin)throws Exception {
            on(()->{client=new SelfServiceClient(null,v->saved.put("s",v),realm,pin);client.createIdentity();return null;});
            loop=new RealtimeLoop(owner,client,new RealtimeLoop.Listener(){public void changed(boolean online,String status){statuses.add(status);}});
            loop.start();
        }
    }
    static boolean hasText(Phone p,String text)throws Exception {
        return p.on(()->{JSONArray d=p.client.publicView().getJSONArray("dialogs");
            for(int i=0;i<d.length();i++){JSONArray m=d.getJSONObject(i).getJSONArray("messages");for(int j=0;j<m.length();j++)if(text.equals(m.getJSONObject(j).optString("text")))return true;}
            return false;});
    }
    public static void main(String[] a)throws Exception {
        Phone one=new Phone(a[0],a[1]),two=new Phone(a[0],a[1]);
        Thread.sleep(4000);
        for(Phone p:new Phone[]{one,two}) {
            if(p.on(()->p.client.registered()))throw new AssertionError("registered without ID login");
            for(String s:p.statuses)if(s.contains("404")||s.toLowerCase(Locale.ROOT).contains("ошибка"))throw new AssertionError("loop error before login: "+s);
        }
        String[] mode=new String[2];
        mode[0]=one.on(()->IdentityLogin.run(one.client.identityDevice(),one.client.identityHttp(),a[2],a[3],false));
        mode[1]=two.on(()->IdentityLogin.run(two.client.identityDevice(),two.client.identityHttp(),a[4],a[5],false));
        if(!mode[0].equals("active")||!mode[1].equals("active"))throw new AssertionError(Arrays.toString(mode));
        // Explicit sharing uses the existing signed card route, independently of
        // any UI/background nickname cache. Network calls must not run on owner.
        for(int n=0;n<2;n++) {
            Phone p=n==0?one:two;String expected=n==0?a[3]:a[5];
            JSONObject before=p.on(()->p.client.publicView());
            String fingerprint=before.getString("contact_fingerprint");
            JSONObject shared=p.loop.directory("directory_card",null);
            if(!Boolean.TRUE.equals(shared.opt("published"))||!expected.equals(shared.optString("name"))
                ||!shared.optString("card").matches("[0-9a-f]{64}"))
                throw new AssertionError("own card acknowledgement/name missing on active server");
            JSONObject after=p.on(()->p.client.publicView());
            if(!before.getString("account").equals(after.getString("account"))
                ||!fingerprint.equals(after.getString("contact_fingerprint")))
                throw new AssertionError("sharing must preserve transport identity/card");
        }
        System.out.println("PASS explicit own-card link lookup: signed current-server response, canonical nick, retained account/card");
        JSONObject c1=one.on(()->one.client.publicView()),c2=two.on(()->two.client.publicView());
        one.on(()->{one.client.pair(c2.getJSONObject("contact").toString(),true);return null;});
        two.on(()->{two.client.pair(c1.getJSONObject("contact").toString(),true);return null;});
        one.on(()->{one.client.send(c2.getString("account"),"Фоновая доставка");return null;});
        one.loop.kick();two.loop.kick();
        long end=System.nanoTime()+60_000_000_000L;
        while(!hasText(two,"Фоновая доставка")){if(System.nanoTime()>end)throw new AssertionError("background loop did not deliver; statuses "+two.statuses+" / "+one.statuses);Thread.sleep(500);}
        one.loop.close();two.loop.close();one.owner.shutdownNow();two.owner.shutdownNow();
        System.out.println("PASS background loop idles until ID login, then delivers E2EE text");
        System.exit(0);
    }
}
