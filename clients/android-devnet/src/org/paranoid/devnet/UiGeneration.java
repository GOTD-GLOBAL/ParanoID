package org.paranoid.devnet;
/** UI-owner generation; worker results may only touch their still-current view. */
final class UiGeneration {
    private final java.util.concurrent.atomic.AtomicLong generation=new java.util.concurrent.atomic.AtomicLong();
    long next(){return generation.incrementAndGet();}
    boolean current(long ticket){return generation.get()==ticket;}
}
