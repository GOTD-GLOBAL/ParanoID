#!/usr/bin/env bash
# One-touch deploy from the build machine: build the server, copy it with install.sh to
# the host over SSH and run the installer. Prints the connection descriptor to pin in
# the app. Requires key-based root SSH (never passwords) and a pinned host key.
#
#   deploy/one-touch/deploy.sh root@203.0.113.10 [ssh options...]
set -euo pipefail
TARGET="${1:?usage: deploy.sh root@HOST [ssh options]}"; shift
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ForwardAgent=no "$@")
SCP=(scp -q -o BatchMode=yes -o StrictHostKeyChecking=yes "$@")
cargo build --release --locked --manifest-path "$ROOT/server/Cargo.toml" >&2
STAGE=$("${SSH[@]}" "$TARGET" 'mktemp -d /root/paranoid-install.XXXXXX')
"${SCP[@]}" "$ROOT/server/target/release/paranoid-server" "$HERE/install.sh" "$TARGET:$STAGE/"
"${SSH[@]}" "$TARGET" "bash $STAGE/install.sh --binary $STAGE/paranoid-server; rc=\$?; rm -rf $STAGE; exit \$rc"
