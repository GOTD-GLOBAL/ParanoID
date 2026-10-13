#!/usr/bin/env bash
# Exact-source, unsigned/local-only entry point for the existing iOS build.
set -Eeuo pipefail
if [[ $# -ne 1 || ! "$1" =~ ^[0-9a-f]{40}$ ]]; then
  printf '%s\n' 'expected full lowercase commit SHA' >&2
  exit 64
fi
if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'macOS with Xcode required; no build performed' >&2
  exit 69
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
if [[ "$(git -C "$ROOT" rev-parse HEAD)" != "$1" ]]; then
  printf '%s\n' 'source commit mismatch; no build performed' >&2
  exit 65
fi
if ! SOURCE_STATUS="$(git -C "$ROOT" status --porcelain --untracked-files=normal)"; then
  printf '%s\n' 'cannot verify source worktree; no build performed' >&2
  exit 67
fi
if [[ -n "$SOURCE_STATUS" ]]; then
  printf '%s\n' 'source worktree is not clean; preserve edits and use a separate worktree' >&2
  exit 66
fi
DESTINATION="${PARANOID_IOS_SIMULATOR:-}"
if [[ ! "$DESTINATION" =~ ^platform=iOS\ Simulator,id=[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
  printf '%s\n' 'explicit simulator UUID required: PARANOID_IOS_SIMULATOR=platform=iOS Simulator,id=<UUID>' >&2
  exit 64
fi
printf '%s\n' 'Exact source checked; running local/simulator and unsigned-device gates only.'
# Never inherit an archive/provisioning gate from an interactive shell.
exec env -u PARANOID_IOS_TEAM_ID -u PARANOID_ASC_KEY_ID \
  -u PARANOID_ASC_ISSUER_ID -u PARANOID_ASC_KEY_PATH \
  -u PARANOID_IOS_TOOLCHAIN bash "$HERE/build.sh"
