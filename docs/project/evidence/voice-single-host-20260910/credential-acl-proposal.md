# Narrow systemd credential compatibility proposal — 2026-09-10

Status: PROPOSED, historical design review input only.
The required Fable review was not obtained; the supplemental model report withheld
implementation, and Gate1 remains NOT RUN. See credential-final-handoff.md. No product source, validator, credential,
unit, account, ACL, service, namespace or network operation was changed by this
subtask. This extends REQ-CALL-006/REQ-DEPLOY-003, RFC-0018/proposed ADR-0012.
Root owns canonical disposition and implementation authorization.

## Observed failure and what is still unknown

Read `credentials/credential-compatibility-finding.md` before this proposal. Two
inert system-manager positive cases failed the same unchanged generic credential
validation; the second retained `credential_validation_failed`. The copied
credential's descriptor owner/mode and exact failing stage were not measured.
All subsequent inert cases stayed NOT RUN. This is not a denied operation or an
unavailable systemd manager. No claim that ACL delivery caused this failure is
justified yet.

Source evidence supports a concrete compatibility hypothesis. The v255
`write_credential` function sets0400 then grants the service UID read access by
ACL, retaining manager ownership; chown is a conditional fallback. Its directory
setup likewise grants the service UID read/execute access. The resulting stat
group-class bits may represent an ACL mask, not group-member read access.
[Primary systemd credential implementation](https://raw.githubusercontent.com/systemd/systemd/v255/src/core/exec-credential.c)
(`write_credential`, lines150–199; directory setup, lines663–679).

The ACL helper starts with the descriptor ACL, adds the named UID, calculates the
mask when needed, and writes it back. This supports the exact five-entry candidate
layout below, but does not replace observation of the installed patched build.
[Primary systemd ACL helper](https://raw.githubusercontent.com/systemd/systemd/v255/src/shared/acl-util.c)
(`fd_add_uid_acl_permission`, lines417–460).

Current relay `deploy/turn/runtime.py:read_secret` permits owner root/euid but only
0400/0600. `deploy/alpha.py:turn_environment` and `server/src/voice_turn.rs:load`
also require0400/0600. The issuer uses a same-UID user manager, so its normal
delivery does not need the system-manager named-user ACL branch. No issuer
compatibility failure has been observed; this proposal does not broaden it.

## Gate 1: one unchanged-guard diagnostic before a runtime change

After independent review, prepare one new, hashed **external test-only** inert
observer. Preserve the original validator function and every confinement property
byte-for-byte; add observation around it, not a second permissive validator.
The first post-open descriptor snapshot is captured before failure/cleanup.

The exact test-only observer under review retains this closed schema:

```text
v: 1
category: credential_validation_failed
stage: one of {manifest_open, manifest_parse, identity, runtime_paths,
              runtime_descriptor, credential_open, credential_descriptor,
              credential_format, credential_content, success_marker}
descriptor: null before credential open; otherwise exactly
  uid: numeric descriptor owner UID
  mode: numeric permission/special bits
  nlink: numeric descriptor link count
  type: numeric stat file-type bits
```

The manifest pins the nonzero service UID; the observed descriptor can therefore
show which unchanged owner/mode predicate fails without recording the credential.
No ACL lookup is included. This schema is intentionally smaller than the initial
draft; source and offline validation are frozen alongside this review input.

No credential bytes, digest, path, environment, xattr/ACL contents, arbitrary
exception text or journal dump enters the observation. A failure marker must be
flushed to the owned evidence output before helper exit; collection must not
depend on an already auto-collected unit. Unit names/parent paths stay exclusively
created, and cleanup remains limited to those exact fixtures.

Run exactly **one** system-good diagnostic with the reviewed synthetic source,
same identity and same no-network confinement. It remains expected to fail under
the unchanged owner/mode guard; changing the observer is not a successful
compatibility result. Do not run the remaining matrix or repeat the case. If the
descriptor shows root0440 and the corresponding unchanged guard fails, record
that observed incompatibility. If it does not, stop and revise this hypothesis
from the actual stage; no validator change follows by inference alone.

No ACL probe, extra privilege, coturn process, packet test, namespace, firewall or
alternative execution route is needed for this diagnostic. The denied
media_discovery work remains untouched.

## Gate 2: proposed relay-only runtime contract

Only after Gate1 confirms the relevant layout and fresh Fable approves this exact
contract, add a dedicated **system relay runtime-copy** reader. Preserve the
existing generic/source `read_secret(path)` 0400/0600 behavior; do not change its
meaning to accept arbitrary0440 paths. Source master/source-copy/installer guards,
alpha issuer guard and Rust issuer loader remain unchanged. No authentication,
HMAC, expiry, E2EE, quota or content-format behavior changes.

The new reader has no caller-controlled arbitrary path or mode-bypass parameter.
Production `main` selects it only for
`/run/credentials/paranoid-turn.service/voice-turn-secret`, with
`CREDENTIALS_DIRECTORY` equal to that exact directory and the existing exact
`RUNTIME_DIRECTORY=/run/paranoid-turn` requirement. A fixture may exercise the
private validator primitives using fixture descriptors; the production entry
point must not accept fixture paths, renamed units or environment overrides.

Open `/run`, then its `credentials` child, then `paranoid-turn.service` using
directory descriptors and O_DIRECTORY|O_NOFOLLOW. Validate each opened directory:
root-owned real trusted ancestors, no special bits or unprivileged write access.
Open only the fixed child filename relative to that final descriptor using
O_RDONLY|O_NOFOLLOW|O_NONBLOCK. Do not validate one pathname and read another.
Check descriptor type, nlink1, exact64-byte metadata length and the unchanged
bounded65-byte content read/ASCII-hex predicate.

The final credential directory must be one of these explicitly supported private
read-only layouts, not merely an arbitrary mode with a group bit:

- euid-owned0500 with no effective non-owner access, for the chown fallback; or
- root-owned0550 with the exact access-ACL pattern below, substituting read/execute
  permission5 for read4 on owner/named-user/mask entries.

For the **file**, the old0400/0600 rules remain valid when readable by the service
under this trusted runtime context. The only new accepted file mode is exact0440,
root-owned, euid nonzero, regular, nlink1, no special bits, and exactly this Linux
POSIX access ACL on the **same opened file descriptor**:

| Ordered tag | Numeric tag | Permission | ID |
| --- | --- | --- | --- |
| USER_OBJ | 0x01 | read only,4 | undefined0xffffffff |
| USER | 0x02 | read only,4 | exactly current euid |
| GROUP_OBJ | 0x04 | none,0 | undefined0xffffffff |
| MASK | 0x10 | read only,4 | undefined0xffffffff |
| OTHER | 0x20 | none,0 | undefined0xffffffff |

There are exactly five entries: no second named user, named group, duplicate,
unknown tag, extra permission or trailing byte. The group owning the inode has
zero ACL permissions regardless of its numeric GID; do not invent an unnecessary group requirement. Reject absent/unreadable/
unsupported/oversized/malformed access ACL for the0440 branch. Never infer the
named-user grant from stat mode alone. The directory uses the same five-entry
shape with permissions5/5/0/5/0 and actual euid.

Recheck descriptor metadata after ACL/content inspection; any observed change in
device/inode/type/UID/GID/mode/link count/size/ctime aborts. For the root-owned ACL
branch the service cannot chmod/chown or rewrite this inode; root and the manager
remain trusted. This is not protection against a malicious root administrator.
The implementation must not chmod/chown, remove ACLs, rewrite the copied
credential, or copy it elsewhere to make the current validator pass.

## Reader alternatives and recommended narrow implementation

**A. Maintained libacl:** use `acl_get_fd`, bounded enumeration, `acl_valid`,
tag/qualifier/permission accessors and `acl_free`. Do not parse `getfacl` output or
look up users by name. This reuses a maintained ACL representation but adds a
runtime library/FFI surface and pinned package/license dependency. An independent
fixed-size `fgetxattr` precheck is still needed if hard read/allocation bounds are
required; enumeration must reject a sixth entry. Loading a library by ambient
search path is not permitted in the packaged launcher.

**B. Exact Linux kernel xattr recognizer — recommended for review:** this is a
recognizer of one fixed ABI shape, not a general ACL parser. The local kernel UAPI
headers `/usr/include/linux/posix_acl_xattr.h` and `posix_acl.h` define a little-
endian version2 uint32 header and five 8-byte entries (`u16 tag,u16 perm,u32 id`).
Total accepted size is exactly44bytes. Issue `fgetxattr(fd,
"system.posix_acl_access", fixed44byte_buffer,44)` once, with explicit ctypes
argument/return types (`int`, pointer, pointer, size_t -> ssize_t) against libc's
already loaded symbol. Reject errors including ERANGE/ENODATA/ENOTSUP and every
returned length other than44; no size-discovery/reallocation/retry loop. Decode
only that fixed layout using `struct` and compare the exact typed entries above.
The kernel API supplies bytes; no syscall, loader or permission fallback is
added. Missing libc symbol/unsupported ABI fails clearly. One private helper
parameter distinguishes the fixed file permission4 and directory permission5
patterns; no arbitrary ACL policy is caller-configurable.

This avoids adding libacl to the six-library relay closure, uses a documented
Linux ABI on the already pinned Linux x86_64 platform, and keeps the new accepted
state narrowly reviewable. The cost is a small security-sensitive typed FFI and
ABI recognizer requiring explicit tests/review. If Fable prefers libacl, select
that option before implementation and re-pin the enlarged closure; do not combine
fallback readers that accept different ACL sets.

**C. Change delivery or broad0440 acceptance:** not selected. Switching systemd
delivery, adding a secret-copy step, stripping ACLs/chowning manager files, or
treating all root0440 files as private expands the change or weakens proof. The
existing source file policy must not be relaxed to accommodate runtime metadata.

## Required evidence and release impact

Before changing production predicates, retain the actual unchanged-guard
diagnostic outcome and source hashes. Then strict TDD needs a positive root0440
exact-ACL fixture that fails the old relay predicate and passes the new dedicated
reader, while the generic/source reader still rejects it. Offline primitive
fixtures must preserve all existing0400/0600/content/descriptor negatives.

Add deterministic rejection cases for wrong version/length/endian/trailing data,
each missing/duplicate/reordered/extra tag, wrong named UID/root UID, named groups,
any group/other bit, write/execute file permission, wrong mask, multiple links,
symlink file or ancestor, wrong runtime path/unit/directory ownership/ACL, unknown
ACL read errors, changed descriptor metadata and malformed64-byte content.
Mocked bounded-fgetxattr tests assert a single call with44-byte capacity and no
fallback after ERANGE. Directory tests distinguish exact0550 ACL and legitimate
euid0500 fallback from ordinary group-readable directories.

After reviewed offline GREEN, one separately coordinated inert compatibility
matrix may exercise actual system/user manager delivery with the production
reader's descriptor primitives, preserved confinement and explicit cleanup. It
must remain labelled **credential primitive evidence**: no coturn/CLI/TURN
lifecycle, refresh/expiry, ACL packet, coordinated full rehearsal or deployment
gate is closed by it. Any failure stops its bounded scope and is preserved.

The final change reopens `runtime.py` and its manifest hash. Update the runtime
credential contract/threat/runbook and affected capability/package records with
the exact source-versus-runtime distinction; rebuild/re-pin TURN and the unified
kit, update acceptance component hashes and obtain fresh final Fable review.
Do not claim the previous packaged launcher check covers these new bytes. The
original opaque worker rejection, TURN-RT01, TURN-ACL02, effective CLI closure,
actual relay lifecycle and deployment remain NOT RUN.
