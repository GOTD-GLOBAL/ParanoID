"""Build a deterministic native unit of the EXACT coturn callback body/headers.

No sockets, threads, credentials or relay runtime. Dependency functions are
explicit test doubles. This proves callback state under selected delivery orders;
the separate VM packet tests exercise the real auth worker and unmodified binary.
Never call this an observed concurrent socket race or full-binary attestation.
"""
import hashlib
import json
from pathlib import Path
import subprocess

PREFIX = r'''
#include "ns_turn_server.h"
#include "ns_turn_ioalib.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static ts_ur_super_session owned_session;
static turn_turnserver owned_server;
static int calls, releases, closes, invalid;
static int observed_key, observed_pwd, observed_lookup;
static ts_ur_super_session *get_session_from_map(turn_turnserver *server, turnsession_id id) {
  return server == &owned_server && id == 1 ? &owned_session : NULL;
}
static void dec_quota(ts_ur_super_session *ss) {(void)ss; invalid++;}
static int inc_quota(ts_ur_super_session *ss, uint8_t *username) {
  (void)ss; (void)username; invalid++; return 0;
}
void get_realm_options_by_name(char *realm, realm_options_t *ro) {
  (void)realm; (void)ro; invalid++;
}
static int read_client_connection(turn_turnserver *server, ts_ur_super_session *ss,
    ioa_net_data *in_buffer, int can_resume, int count_usage) {
  if (server != &owned_server || ss != &owned_session || !in_buffer->nbh || can_resume || count_usage) invalid++;
  calls++; observed_key = ss->hmackey_set; observed_pwd = ss->pwd[0] != 0;
  observed_lookup = ss->key_lookup_result; return 0;
}
void close_ioa_socket_after_processing_if_necessary(ioa_socket_handle s) {
  if (s != owned_session.client_socket) invalid++; closes++;
}
void ioa_network_buffer_delete(ioa_engine_handle e, ioa_network_buffer_handle nbh) {
  if (e != owned_server.e || !nbh) invalid++; releases++;
}
'''

SUFFIX = r'''
static void deliver(int success, turn_key_lookup_result outcome, unsigned char keybyte) {
  hmackey_t key; password_t pwd; ioa_net_data data;
  memset(key, keybyte, sizeof(key)); memset(pwd, 0, sizeof(pwd));
  if (success) memcpy(pwd, "own-verified-password", 21);
  memset(&data, 0, sizeof(data)); data.nbh = (ioa_network_buffer_handle)&data;
  int prior_calls = calls, prior_releases = releases, prior_closes = closes;
  resume_processing_after_username_check(success, outcome, 0, 60, key, pwd,
      &owned_server, 1, &data, NULL);
  if (data.nbh || calls != prior_calls + 1 || releases != prior_releases + 1 || closes != prior_closes + 1) invalid++;
  if (success && (memcmp(owned_session.hmackey, key, sizeof(key)) ||
      memcmp(owned_session.pwd, pwd, sizeof(pwd)))) invalid++;
}
int main(void) {
  memset(&owned_server, 0, sizeof(owned_server)); memset(&owned_session, 0, sizeof(owned_session));
  owned_session.server = &owned_server;
  owned_session.client_socket = (ioa_socket_handle)&owned_session;
  deliver(1, TURN_KEY_LOOKUP_OK, 0xa5);
  int normal_success = observed_key && observed_pwd && observed_lookup == TURN_KEY_LOOKUP_OK;
  /* The failed response was pending while the preceding success restored a key.
   * Deliver the failure last, exactly the state/order that the patch must handle. */
  deliver(0, TURN_KEY_LOOKUP_EXPIRED, 0x00);
  int expiry_cleared = !observed_key && !observed_pwd && observed_lookup == TURN_KEY_LOOKUP_EXPIRED;
  deliver(1, TURN_KEY_LOOKUP_OK, 0x5a);
  deliver(0, TURN_KEY_LOOKUP_INTEGRITY_MISMATCH, 0x00);
  int mismatch_cleared = !observed_key && !observed_pwd && observed_lookup == TURN_KEY_LOOKUP_INTEGRITY_MISMATCH;
  printf("{\"normal_success\":%s,\"expired_after_success_cleared\":%s,"
         "\"mismatch_after_success_cleared\":%s,\"resume_calls\":%d,"
         "\"buffers_released\":%d,\"socket_finishes\":%d,\"invalid\":%d}\n",
         normal_success?"true":"false", expiry_cleared?"true":"false",
         mismatch_cleared?"true":"false", calls, releases, closes, invalid);
  return normal_success && expiry_cleared && mismatch_cleared && !invalid ? 0 : 1;
}
'''


def build(source, output, expected_source_sha256):
    source, output = Path(source), Path(output)
    path = source / 'src/server/ns_turn_server.c'
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != expected_source_sha256:
        raise ValueError('exact reviewed coturn source required')
    beginning = b'static void resume_processing_after_username_check('
    ending = b'\nstatic int check_stun_auth('
    if raw.count(beginning) != 1 or raw[raw.index(beginning):].count(ending) != 1:
        raise ValueError('unique complete callback definition required')
    body = raw[raw.index(beginning):raw.index(ending, raw.index(beginning))]
    if not 1000 < len(body) < 6000 or not body.rstrip().endswith(b'}'):
        raise ValueError('bounded complete callback source required')
    output.mkdir(mode=0o700)
    (output / 'exact-callback.c').write_bytes(body)
    harness = output / 'callback-harness.c'
    # Vendor notice accompanies the exact copied body in this derived test unit.
    harness.write_bytes(raw[:raw.index(b'#include')] + PREFIX.encode() + body + SUFFIX.encode())
    includes = [source, source / 'src', source / 'src/server', source / 'src/client',
                source / 'src/apps/common', source / 'src/apps/relay']
    command = ['/usr/bin/cc', '-std=c11', '-D_GNU_SOURCE', '-O0', '-g0', '-Wall', '-Wextra',
               '-Werror', '-Wno-unused-parameter', '-Wno-misleading-indentation', '-MD',
               '-MF', str(output / 'headers.d'), *[flag for p in includes for flag in ('-I', str(p))],
               str(harness), '-o', str(output / 'callback-harness')]
    result = subprocess.run(command, capture_output=True, timeout=60)
    (output / 'compile.log').write_bytes(result.stdout + result.stderr)
    report = {'kind': 'exact-callback-native-unit-build', 'source_sha256': expected_source_sha256,
              'callback_sha256': hashlib.sha256(body).hexdigest(), 'argv': command,
              'compile_exit': result.returncode,
              'harness_source_sha256': hashlib.sha256(harness.read_bytes()).hexdigest()}
    if result.returncode == 0:
        # -MD includes actual system/compiler headers as well as vendor headers.
        words = (output / 'headers.d').read_text().replace('\\\n', '').split()[1:]
        report['headers_sha256'] = {name: hashlib.sha256(Path(name).read_bytes()).hexdigest() for name in words}
        report['binary_sha256'] = hashlib.sha256((output / 'callback-harness').read_bytes()).hexdigest()
    (output / 'build.json').write_text(json.dumps(report, indent=2) + '\n')
    return report
