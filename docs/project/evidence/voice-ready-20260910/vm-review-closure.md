# RAM-only capability review closure — 2026-09-10

Actual independent claude-opus-5 review permits acquisition and one boot after
ACQ1–3/BOOT1–4 corrections. No denied resource/job is retried. Review and original
source/freeze snapshots remain intact. This closure is implementation evidence,
not a new reviewer verdict or proof that a guest has run.

ACQ1: source/plan/chain/verifier checked against the amended freeze before acquisition.
ACQ2: outer failure envelope records stage, package, exception and bounded actual
error detail for download/extraction/version/library/input/manifest failures.
ACQ3: complete sysroot inventory records all files/hashes/modes, directories and
relative symlink targets; boot independently verifies it, including modules and ROMs.
ACQ4: new verifier records Date/Valid-Until and current UTC, rejects future or expired
metadata when publisher supplies expiry; absence recorded explicitly. Actual
signature→index→18 package stanzas verified in apt-chain-v3.json.
ACQ5: removed unused genisoimage/cdrkit package and executable entirely (planv3,
34492848 download bytes). qemu-img retained only as an inert format inspection
utility for future separately reviewed fixture; boot never invokes it.
ACQ6: plan origins labelled advisory; actual signed stanza chain is authority.
Host dpkg-deb hash and root-controlled tool/library ancestor checks added.
ACQ7: exact HTTPS archive pool URI validated before request; redirects refused.
All temporary expanded tar files now stay under owned output directory.

BOOT1: tooling source/plan/chain receipt hashes must equal amended freeze; whole
extracted tree compared before boot. BOOT2: actual argv, UID/capability, each fd and
QMP inventories saved before their assertions. Strict fd guard stays unchanged,
including rejection of unexpected /memfd targets; no weakening to force a boot.
BOOT3: console hash/size/UTF8 decode outcome saved in finally even on failure.
BOOT4: guest explicitly reports ipv6_route=absent|present and parser requires it.
BOOT5: JSON explicitly says point-in-time observation, pre-cont inventory.
BOOT6: QMP stream drained with byte/event bounds after cont; EOF unregisters the
pipe and leaves process exit/guest-result checks authoritative, no retry.
BOOT8: actual BusyBox --list must contain every applet used before a VM starts.

Eight offline tests pass against final source: parser/nonce/IPv6/device rejection,
newc input inventory, exact shared tree-validator AST, file mutation/writable-node/
symlink-escape rejection. No runtime isolation asserted. Frozen run-once exclusive
output dirs, fixed no-network argv, QEMU sandbox, unprivileged TCG, resource limits,
source signature chain, no host package/firewall/account/mount changes all remain.
Further packet/relay/coordinator/current-call/deployment gates remain NOT RUN.
