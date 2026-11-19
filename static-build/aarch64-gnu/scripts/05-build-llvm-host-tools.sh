#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

LLVM_HOST_BUILD="${BUILD}/llvm-host-tools"

# Deliberately do not source cross compiler variables in the CMake invocation.
# This stage creates new x86_64 generators used only while cross-compiling LLVM.
env -u CC -u CXX -u AR -u RANLIB -u STRIP -u NM -u OBJCOPY -u OBJDUMP \
  -u CPATH -u LIBRARY_PATH -u PKG_CONFIG_LIBDIR \
  cmake -S "${SOURCES}/llvm-project/llvm" \
    -B "${LLVM_HOST_BUILD}" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${HOST_TOOLS}" \
    -DLLVM_ENABLE_PROJECTS=clang \
    -DLLVM_TARGETS_TO_BUILD="AArch64;BPF" \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_BUILD_TOOLS=ON \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF

cmake --build "${LLVM_HOST_BUILD}" --parallel "${JOBS}" \
  --target llvm-tblgen clang-tblgen llvm-config llvm-objcopy

mkdir -p "${HOST_TOOLS}/bin"
for tool in llvm-tblgen clang-tblgen llvm-config llvm-objcopy; do
  install -m755 "${LLVM_HOST_BUILD}/bin/${tool}" "${HOST_TOOLS}/bin/${tool}"
done

file "${HOST_TOOLS}/bin/"*

