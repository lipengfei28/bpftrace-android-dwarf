#!/usr/bin/env bash
set -Eeuo pipefail

# LLVM's nested NATIVE build must not see AArch64 headers or libraries.
exec env \
  -u CPATH \
  -u CPLUS_INCLUDE_PATH \
  -u C_INCLUDE_PATH \
  -u LIBRARY_PATH \
  -u PKG_CONFIG_SYSROOT_DIR \
  -u PKG_CONFIG_LIBDIR \
  -u PKG_CONFIG_PATH \
  /usr/bin/gcc "$@"
