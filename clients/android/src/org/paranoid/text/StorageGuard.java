package org.paranoid.text;
import java.io.IOException;
/** A retained wrapping key without its snapshot is NOT a fresh installation. */
public final class StorageGuard {
    public static final String ALIAS="paranoid-text-state-v0";
    private StorageGuard(){}
    public static void requireContinuity(boolean snapshot,boolean alias) throws IOException {
        if(snapshot!=alias)throw new IOException("incomplete retained state; no regeneration");
    }
}
