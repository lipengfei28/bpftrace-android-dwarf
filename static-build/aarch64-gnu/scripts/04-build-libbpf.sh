#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

LIBBPF_OBJ="${BUILD}/libbpf"
mkdir -p "${LIBBPF_OBJ}"

make -C "${SOURCES}/libbpf/src" -j"${JOBS}" \
  OBJDIR="${LIBBPF_OBJ}" \
  CC="${CC}" \
  AR="${AR}" \
  CFLAGS="-O2 -fPIC -I${PREFIX}/include" \
  LDFLAGS="-L${PREFIX}/lib" \
  BUILD_STATIC_ONLY=1

make -C "${SOURCES}/libbpf/src" \
  OBJDIR="${LIBBPF_OBJ}" \
  CC="${CC}" \
  AR="${AR}" \
  BUILD_STATIC_ONLY=1 \
  PREFIX="${PREFIX}" \
  LIBDIR="${PREFIX}/lib" \
  UAPIDIR="${PREFIX}/include" \
  install install_uapi_headers

require_file "${PREFIX}/lib/libbpf.a"
echo "libbpf installed under ${PREFIX}"

