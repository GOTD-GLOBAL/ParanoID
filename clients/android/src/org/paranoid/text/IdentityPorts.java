package org.paranoid.text;

import org.json.JSONObject;

/** RFC-0027 identity-v3 login boundaries, kept in the messenger package so the core client
 * does not depend on the optional Devnet module. Only public data crosses them. */
public final class IdentityPorts {
    private IdentityPorts(){}
    /** Pinned TLS HTTP to the saved messenger server; throws SyncCycle.Rejected on non-200. */
    public interface Http { JSONObject post(String path,String body)throws Exception; }
    /** The messenger core: public credential, device proof and committing an active status. */
    public interface Device {
        JSONObject credential()throws Exception;
        String deviceProof(JSONObject intent,JSONObject challenge,long now)throws Exception;
        void active(JSONObject status)throws Exception;
    }
}
