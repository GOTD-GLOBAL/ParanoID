#!/usr/bin/env bash
# Run a command with the pinned iOS toolchain environment.
# Non-interactive shells on this Mac do not have ~/.cargo/bin (rustup proxies)
# on PATH; every build/test step is expected to go through this wrapper.
# Usage: bash clients/ios/toolchain.sh <command> [args...]
set -euo pipefail
umask 077
export PATH="$HOME/.cargo/bin:$PATH"
if [ "$#" -eq 0 ]; then
  echo "usage: toolchain.sh <command> [args...]" >&2
  exit 64
fi
exec "$@"
