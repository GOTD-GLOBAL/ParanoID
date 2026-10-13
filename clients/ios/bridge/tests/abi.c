/* Public synthetic vectors only. Compiled and linked against the actual staticlib. */
#include "paranoid_core.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    const char *recover = "{\"op\":\"recover\",\"mnemonic\":\"abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about\"}";
    for (int i = 0; i < 32; ++i) {
        char *reply = paranoid_devnet_command(recover);
        assert(reply != NULL);
        assert(strcmp(reply, "{\"entropy\":\"AAAAAAAAAAAAAAAAAAAAAA==\"}") == 0);
        paranoid_devnet_free(reply);
    }
    char *identity = paranoid_devnet_command("{\"op\":\"identity\",\"entropy\":\"AAAAAAAAAAAAAAAAAAAAAA==\"}");
    assert(identity != NULL);
    assert(strstr(identity, "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk") != NULL);
    paranoid_devnet_free(identity);
    paranoid_devnet_free(NULL);
    char *failure = paranoid_devnet_command(NULL);
    assert(strcmp(failure, "{\"error\":\"invalid_request\"}") == 0);
    paranoid_devnet_free(failure);
    char *core = paranoid_core_command("", "not json");
    assert(strcmp(core, "{\"error\":\"invalid_request\"}") == 0);
    paranoid_core_free(core);
    puts("PASS: real C header/staticlib recovery, identity, allocation/free, core ABI");
    return 0;
}
