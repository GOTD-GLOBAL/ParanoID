# ParanoID native private-alpha bundle

This artifact is for two informed OPPO testers with non-sensitive data only.
It is NOT production-ready or a claim of phone-to-phone acceptance. No E2EE
content keys are provided to the server. Review the manifest/checksums and source
before executing it. Hashes are not publisher signatures.

Prerequisites: Linux x86_64 compatible libc/libgcc, Python 3, OpenSSL, PostgreSQL
16 binaries at `/usr/lib/postgresql/16/bin`, systemd user manager, a dedicated
unprivileged account with a private persistent home, available IP port 38443,
and sufficient disk/RAM. IPv4 only; IPv6 is explicitly rejected.
No Docker, Nginx or existing DB is used. No package
installer, sudo or firewall changes are performed. Check user lingering for
boot/logout persistence through an authorized administrator before rollout.

After bounded authorization, as the dedicated account, from the extracted bundle:

```sh
python3 alpha.py install --root /home/paranoid/paranoid-alpha \
  --ip 157.180.49.125 --release "$PWD"
python3 alpha.py health --root /home/paranoid/paranoid-alpha
```

Installation refuses existing root/unit. It enables only `paranoid-alpha.service`.
Use a real absolute paranoid-* root with no symlink ancestors or traversal.
Persistent directories must remain private, real and account-owned; do not
redirect data/socket/releases/backups/TLS with symlinks. Config and lock files
must be private, single-link regular files. Config has exactly `ip`, `alice`,
`bob`: a canonical IPv4 string and distinct 64-hex admission tokens.
Current must point directly to a verified releases/<id> directory; dot/dotdot
IDs, unexpected release members and preexisting `next` are refused. Invalid
state/candidate collisions fail before stopping a service or writing backups.
Preserve and inspect rejected partial state; never reset it by deleting history.
TLS key, independent Alice/Bob admission tokens and private PG16 data stay outside
releases. Provision `tls/public-connection.json` (public URL/SPKI) out of band.
Privately provision only each tester's own token from restricted `config.json`;
never print it to logs, URLs, shell arguments or shared chat. Peer Olm identity
verification is separate. TLS certificates expire after 90 days; renewal/key
rotation is an explicit operator procedure, not automatic repinning.

Update or code rollback (use the desired reviewed extracted or retained release):

```sh
python3 alpha.py update --root /home/paranoid/paranoid-alpha \
  --release /absolute/path/to/desired/release
```

Only identical schema hashes are permitted. The command stops only its matching
unit, makes a private logical dump, restores it into a fresh verification DB,
compares all history/state, switches code, restarts and checks TLS/database health.
Failed update readiness attempts the old code without overwriting current history.
All releases, dumps, verification databases and live history remain: monitor disk.
Never restore an old dump over live data to roll back code. No schema/PG-major
upgrade, backup encryption/transfer or automatic disaster recovery is included.
Do not run lifecycle commands concurrently. Preserve a trusted controller copy.

For an extra backup: stop only this user unit, run `python3 alpha.py backup --root
/home/paranoid/paranoid-alpha`, restart it and run health. No automatic data/key
removal or failed-install reset exists. Use synthetic data only; remote boot,
host-loss recovery and physical OPPO acceptance are separate checks.

Canonical operator runbook: `docs/operations/linux-alpha-deployment.md` in the
reviewed source repository, with RFC-0009 and draft ADR-0005. Local tests exercise
real systemd/PostgreSQL/direct TLS; they are not Docker or production-host evidence.
