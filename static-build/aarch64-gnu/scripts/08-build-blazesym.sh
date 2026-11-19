#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

command -v cargo >/dev/null
rustup target list --installed | grep -qx aarch64-unknown-linux-gnu || {
  echo "Rust target aarch64-unknown-linux-gnu is not installed." >&2
  echo "Run: rustup target add aarch64-unknown-linux-gnu" >&2
  exit 1
}

export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="${CC}"
export PKG_CONFIG_ALLOW_CROSS=1
export PKG_CONFIG_SYSROOT_DIR=
export XZ2_STATIC=1

(
  cd "${SOURCES}/blazesym"
  cargo build \
    --locked \
    --offline \
    --release \
    --target aarch64-unknown-linux-gnu \
    -p blazesym-c \
    --features blazesym/xz
)

install -m644 \
  "${SOURCES}/blazesym/target/aarch64-unknown-linux-gnu/release/libblazesym_c.a" \
  "${PREFIX}/lib/libblazesym_c.a"
install -m644 \
  "${SOURCES}/blazesym/capi/include/blazesym.h" \
  "${PREFIX}/include/blazesym.h"
