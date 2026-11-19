#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

build_install_cmake bcc "${SOURCES}/bcc" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=OFF \
  -DCMAKE_PREFIX_PATH="${PREFIX}" \
  -DLLVM_DIR="${PREFIX}/lib/cmake/llvm" \
  -DClang_DIR="${PREFIX}/lib/cmake/clang" \
  -DCMAKE_USE_LIBBPF_PACKAGE=ON \
  -DNO_BLAZESYM=ON \
  -DENABLE_LLVM_SHARED=ON \
  -DENABLE_LLVM_NATIVECODEGEN=OFF \
  -DENABLE_CLANG_JIT=ON \
  -DENABLE_USDT=ON \
  -DENABLE_LIBDEBUGINFOD=OFF \
  -DENABLE_EXAMPLES=OFF \
  -DENABLE_TESTS=OFF \
  -DENABLE_MAN=OFF \
  -DREVISION="${BCC_REV}"

find "${PREFIX}/lib" -maxdepth 1 -name 'libbcc*.so*' -exec file -L {} \;
