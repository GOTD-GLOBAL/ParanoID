package org.paranoid.text;

public final class CoreBridge {
    static { System.loadLibrary("paranoid_client_core"); }
    private CoreBridge() {}
    public static native String command(String state, String request);
}
