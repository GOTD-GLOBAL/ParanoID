---
status: draft
owner: operations
last_reviewed: 2026-09-07
---

# Production SSH access from Hermes

## Scope and authority

This runbook records owner-provided infrastructure facts and a read-only access
check, not an accepted deployment architecture. Provisioning an account does not
mean ParanoID is deployed. It does not authorize deployment, package installation,
service restarts, firewall changes, or modifications to neighboring services.
Changes require separately scoped authorization and applicable governance review.
The production host is distinct from the Hermes build host.

## Owner-provided inventory

- Host: `157.180.49.125`, SSH port `22`.
- Project account: `paranoid` (use instead of `exponenta`).
- Home: `/home/paranoid`; shell: `/bin/bash`.
- Sudo policy reported by owner: `(ALL:ALL) NOPASSWD: ALL`.
- Authorized shared key label: `hermes-codex-multi-server`.

On the Hermes host:

- Encrypted private credential: `/etc/credstore.encrypted/hermes-servers-ssh-key`.
- Public identity file: `/home/codex/.ssh/hermes_servers_ed25519.pub`.
- Host trust file: `/home/codex/.ssh/known_hosts`.

These are paths and identifiers, not credential contents. The shared key and broad
sudo access increase compromise impact; this runbook does not endorse or expand
those privileges. Never reuse this access to change other projects implicitly.

## Read-only verification

Run with Bash, without shell tracing. Load the decrypted key only through a pipe
into a temporary agent; never print it or write it to a decrypted file. Do not
forward the agent to the remote host. Preserve host-key verification: if it fails,
stop and verify the fingerprint independently with the operator. Do not disable
checking, delete the existing host entry, or blindly accept a replacement.

```bash
(
  set -euo pipefail
  eval "$(ssh-agent -s)" >/dev/null
  trap 'ssh-agent -k >/dev/null' EXIT

  sudo -n systemd-creds decrypt \
    /etc/credstore.encrypted/hermes-servers-ssh-key - \
    | ssh-add - >/dev/null 2>&1

  ssh \
    -p 22 \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile=/home/codex/.ssh/known_hosts \
    -o IdentitiesOnly=yes \
    -o ForwardAgent=no \
    -o ConnectTimeout=15 \
    -i /home/codex/.ssh/hermes_servers_ed25519.pub \
    paranoid@157.180.49.125 \
    'id; sudo -n id'
)
```

## Observed evidence

Read-only SSH verification on 2026-09-07 exited with code 0 and returned:

```text
uid=1003(paranoid) gid=1004(paranoid) groups=1004(paranoid)
uid=0(root) gid=0(root) groups=0(root)
```

This proves login as `paranoid` and noninteractive sudo execution of `id` at that
check. Home, shell, authorized-key contents and the complete sudo policy were
reported by the owner, not independently inspected. No deployment or adjacent
service was inspected or changed. Routine SSH/sudo access may produce server audit
logs; read-only here means no intentional configuration or application mutation.
The agent is terminated by the EXIT trap, including after command failures.
