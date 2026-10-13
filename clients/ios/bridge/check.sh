#!/usr/bin/env bash
# Offline component checks only: NOT an iOS app build or device acceptance.
# Prerequisite: Rust 1.98.1 + clippy/rustfmt, three Apple std targets and locked
# crate sources installed. Run with bash; works from any current directory.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"
export RUSTUP_TOOLCHAIN=1.98.1
export PYTHONDONTWRITEBYTECODE=1
# Pin outputs as well as inputs; never accidentally link a different target-dir.
export CARGO_TARGET_DIR="$HERE/target"
MANIFEST="$HERE/Cargo.toml"

rustc --version
cargo --version
python3 "$HERE/tests/test_lock.py"
python3 "$HERE/../test_bridge_lock.py"
cargo fmt --manifest-path "$MANIFEST" -- --check
cargo clippy --offline --locked --manifest-path "$MANIFEST" --all-targets -- -D warnings
cargo test --offline --locked --manifest-path "$MANIFEST"
# Upstream crate tests use its own unchanged Android lock, NOT the combined graph.
cargo test --offline --locked --manifest-path "$HERE/../../../blockchain/solana/client/Cargo.toml" --lib
cargo test --offline --locked --release --manifest-path "$MANIFEST" --test devnet_memory
for target in aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin; do
  printf 'Apple type-check only: %s\n' "$target"
  cargo check --offline --locked --target "$target" --manifest-path "$MANIFEST"
done
cargo build --offline --locked --manifest-path "$MANIFEST"
case "$(uname -s)" in
  Linux) LIBS=(-ldl -lpthread -lm) ;;
  Darwin) LIBS=(-framework Security -liconv -lresolv) ;;
  *) printf '%s\n' 'Unsupported C smoke host' >&2; exit 1 ;;
esac
cc -std=c11 -Wall -Wextra -Werror -I"$HERE/include" "$HERE/tests/abi.c" \
  "$CARGO_TARGET_DIR/debug/libparanoid_ios_bridge.a" "${LIBS[@]}" \
  -o "$CARGO_TARGET_DIR/abi-c"
"$CARGO_TARGET_DIR/abi-c"
python3 "$HERE/../notices.py" --offline
python3 "$HERE/../test_notices.py"
printf '%s\n' 'PASS: bridge component checks only; native iOS app/device gates remain separate'
