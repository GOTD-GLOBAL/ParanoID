package org.paranoid.text;

import java.io.IOException;
import java.util.function.BooleanSupplier;

/** Direction failures are independent; uncertain local state is always fatal. */
public final class SyncCycle {
    private SyncCycle() {}
    public static final class Rejected extends IOException {
        public final int status;
        public final String code;
        public Rejected(int status){this(status, "");}
        public Rejected(int status,String code){super("HTTP request rejected");this.status=status;this.code=code;}
    }
    public interface Sender<T> { void send(T item) throws Exception; }
    public static <T> void drain(Iterable<T> snapshot,Sender<T> sender,BooleanSupplier frozen)throws Exception {
        guard(frozen);Rejected blocked=null;
        for(T item:snapshot) {
            guard(frozen);
            try {sender.send(item);guard(frozen);}
            catch(Rejected rejection) {
                guard(frozen);
                if(rejection.status!=409 && rejection.status!=507)throw rejection;
                if(blocked==null)blocked=rejection;
            }
        }
        if(blocked!=null)throw blocked;
    }
    public interface Action { void run() throws Exception; }
    private static void guard(BooleanSupplier frozen) throws IOException,InterruptedException {
        if(frozen.getAsBoolean())throw new IOException("local state is frozen");
        if(Thread.currentThread().isInterrupted())throw new InterruptedException("sync interrupted");
    }
    public static void run(Action outbound,Action inbound,BooleanSupplier frozen) throws Exception {
        guard(frozen);
        Exception firstFailure=null;
        try {outbound.run();}
        catch(Exception failure) {
            if(failure instanceof InterruptedException) {Thread.currentThread().interrupt();throw failure;}
            guard(frozen); // Never treat an ambiguous local commit as a network failure.
            firstFailure=failure;
        }
        guard(frozen);
        try {
            inbound.run();guard(frozen);
            // This can resolve a transient initial failure and flush new receipts.
            // A still-failing outbox is reported, never silently dropped.
            outbound.run();guard(frozen);
        } catch(Exception failure) {
            if(failure instanceof InterruptedException)Thread.currentThread().interrupt();
            if(firstFailure!=null && firstFailure!=failure)failure.addSuppressed(firstFailure);
            throw failure;
        }
    }
}
