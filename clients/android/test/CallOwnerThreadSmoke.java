import org.paranoid.text.CallController;

/** Android/JVM Thread ownership, not a Swift actor API parity scenario. */
public final class CallOwnerThreadSmoke {
    static void check(boolean value,String message){CallControllerSmoke.check(value,message);}
    static void explicitOwnerThread() throws Exception {
        // Regression (v24, 2026-09-13): engine created on a push thread, tick on main -> "call owner thread".
        final Thread main=Thread.currentThread();final CallControllerSmoke.Time time=new CallControllerSmoke.Time();final CallControllerSmoke.Port port=new CallControllerSmoke.Port();
        final CallController[] built=new CallController[1];final Throwable[] failure=new Throwable[1];
        Thread creator=new Thread(()->{try{built[0]=new CallController(time,port,main);}catch(Throwable t){failure[0]=t;}});
        creator.start();creator.join();check(failure[0]==null&&built[0]!=null,"controller built on a foreign thread with explicit owner");
        port.controller=built[0];built[0].connection(true);built[0].tick();check(!built[0].active(),"explicit owner thread may tick a controller built elsewhere");
        final boolean[] rejected=new boolean[1];
        Thread stranger=new Thread(()->{try{built[0].tick();}catch(IllegalStateException expected){rejected[0]=true;}});
        stranger.start();stranger.join();check(rejected[0],"non-owner thread is still rejected");
        boolean nullRejected=false;try{new CallController(time,port,null);}catch(IllegalArgumentException expected){nullRejected=true;}check(nullRejected,"null owner rejected");
    }
    public static void main(String[] args)throws Exception {explicitOwnerThread();System.out.println("CallOwnerThreadSmoke PASS");}
}
