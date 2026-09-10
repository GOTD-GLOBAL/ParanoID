# Exact full guest package acquisition scope — 2026-09-10

Source preparation only. This operation downloads/extracts official signed Ubuntu
packages into an owned directory; no guest binary, VM, service, socket test or
host installation is run. It is a distinct follow-on to the successful18-package
tooling acquisition, not a rerun of any denied fetch/worker. Only canonical archive
URLs from the signed plan are eligible; concrete refusal stops with no reroute.

full-guest-media-plan.json contains205 packages,242329242 bytes (below256MiB).
They provide systemd/user-manager/PG16/Python3.12/cryptography/nft/UFW/iproute2,
matching6.8.0-139 kernel modules, and Java21/headless emulator library dependencies.
The earlier148-package design omitted Java/media dependencies; full-media-inputs.json
now separately pins retained aiortc1.15.0 and its CPython3.12 packages, SDK emulator,
SDK35 official system image and adb. This acquisition does not copy or run those
retained media inputs; their later guest assembly/execution needs exact review.
No guest sudo root requested; guest fixture is root and uses runuser/setpriv.

Actual full-guest-media-chain.json records root-controlled pinned Ubuntu keyring,
gpgv valid signature→decompressed Packages hash/size→exact every package stanza,
plus explicit publisher Date/Valid-Until checks. Missing publisher expiry is
recorded, not inferred. Source/plan/chain/verifier hashes must match a frozen
review manifest before acquisition. Existing cache copies are used only after
regular single-link owned-file checks and exact pinned hash/size verification.
No bad cache entry is silently replaced or downloaded around.

acquire_full_guest.py is unprivileged UID1003, output exclusively
voice-ready-20260910T065350Z/full-guest-packages. No root code runs. >=64GiB free
space before every package and at completion. <=256MiB total input,<=2GiB total
expanded regular bytes,<=20000 tar nodes per package, OS file-size cap1GiB including
the single temporary tar stream. Fixed filesystem layout below owned output,
private temporary stream, no host package/dbus/account/firewall/mount/namespace
changes. No maintainer script or extracted guest executable runs on the host.

Merged-usr guest directories/relative aliases are constructed inside output only.
Absolute guest symlinks are converted to semantically equivalent relative links,
using resolved WITHIN-TREE parents/targets (so /lib64→usr/lib64 does not create
an erroneous usr/usr path). Every conversion is recorded. Tar data filter remains
enabled for every member, escape/host-root targets refused. Regular files lose
privileged mode bits under that filter; guest fixture runs explicit root/runuser
operations and does not require host-style setuid programs. Complete resulting
file/mode/symlink/directory manifest, package provenance and bounded failure
stage/package/exception are recorded. No TOOLS/VM/runtime PASS envelope is generated;
maximum result GUEST_PACKAGES_VERIFIED_NO_VM_STARTED.

Ten offline tests validate conversion and final-tree meaning, ownership/modes,
node types, cache ancestors, freeze/chain mismatch, URI and redirect refusal.
The acquisition source is parsed for syntax; acquisition remains UNRUN at freeze. This is a request for exact acquisition source review ONLY; KVM launcher,
full guest bootstrap, coordinator profile and packet/call drivers remain subject
to their own exact source and artifact review before execution.

## Exact acquisition review closure

Independent actual claude-opus-5 review is CONDITIONAL on C1–C6; original inputs
are preserved in full-guest-acquisition-original. All six changes are applied.
C1: absolute /usr/bin/dpkg-deb, fixed three-variable environment and recorded full
argv. dpkg-deb-toolchain.json pins the root-controlled executable, loader and six
linked libraries including liblzma/libzstd. A real bounded execve trace of our
preexisting pinned BusyBox archive showed only dpkg-deb exec; readelf confirms
in-process linked decompressors. The review's unconditional assertion of external
xz/zstd is not borne out by this observed build. Both helper binaries are also
pinned defensively without claiming they executed. C2: umask0022 and explicit
output-directory modes. C3: every converted link is revalidated against the
final tree and original guest absolute target; a meaning change fails closed.
C4: cache ancestors must be directories owned by root or UID1003 and not group/
other-writable; own archives retain strict single-link regular-file checks.
C5: noble-security is not consulted. Neither used index publishes Valid-Until;
65 packages use a signed noble index dated2024-04-25 without expiry binding, and
the noble-updates index is dated2026-09-10. This is frozen signed provenance,
not a claim of latest security fixes. Integrity of the exact reviewed freeze is
an out-of-band operator precondition, not a self-authenticating trust anchor.
C6: ten offline tests cover the named guard branches with no network or dpkg.
Per-deb decompression timeout is60 seconds for the largest39/46MB signed payloads.
The output is exclusive and non-resumable; any failure is retained and cannot
be silently retried or replaced. No maintainer scripts run; guest boot setup is
still separate. Stripped setuid/xattrs are not dependencies; PostgreSQL must run
as its own guest non-root account. No relay/runtime gate is claimed by acquisition.
