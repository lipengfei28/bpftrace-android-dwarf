#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_file "${HOST_TOOLS}/bin/llvm-tblgen"
require_file "${HOST_TOOLS}/bin/clang-tblgen"
require_file "${HOST_TOOLS}/bin/llvm-config"

# A fully static bpftrace cannot use the PIC archives from the shared build:
# the resulting AArch64 GOT overflows when Clang/LLVM, BCC and glibc are
# combined. Keep this build separate and install its non-PIC archives over
# the private prefix.
LLVM_TARGET_BUILD="${BUILD}/llvm-aarch64-static-nopic"
LLVM_NATIVE_BUILD="${BUILD}/llvm-native-x86_64-static-nopic"
HOST_CC_WRAPPER="${SCRIPT_DIR}/host-gcc-clean-env.sh"
HOST_CXX_WRAPPER="${SCRIPT_DIR}/host-gxx-clean-env.sh"

require_file "${HOST_CC_WRAPPER}"
require_file "${HOST_CXX_WRAPPER}"

# LLVM creates its nested host build below the target build directory as
# "${LLVM_TARGET_BUILD}/NATIVE".  If an earlier invocation configured that
# directory with the target compiler, CMake considers the nested cache
# complete and will never consume the host compiler flags below.  Remove only
# this stale nested cache so the target build itself can be resumed.
LLVM_NATIVE_NESTED_BUILD="${LLVM_TARGET_BUILD}/NATIVE"
if [[ -f "${LLVM_NATIVE_NESTED_BUILD}/CMakeCache.txt" ]] &&
  grep -Eq 'CMAKE_(C|CXX)_COMPILER:.*aarch64-linux-gnu' \
    "${LLVM_NATIVE_NESTED_BUILD}/CMakeCache.txt"; then
  rm -rf "${LLVM_NATIVE_NESTED_BUILD}"
  rm -rf "${LLVM_TARGET_BUILD}/NATIVE-stamps"
fi

# common.sh exports the target compilers and target include/library paths for
# Autoconf-based dependency builds.  Do not leak those variables into LLVM's
# nested NATIVE build: that sub-build produces helper programs which must run
# on the x86_64 build host.  The outer build remains an AArch64 build because
# the CMake toolchain file selects every target compiler explicitly.
unset CC CXX AR RANLIB STRIP NM OBJCOPY OBJDUMP READELF

# Keep CPATH/LIBRARY_PATH for the AArch64 compile. In particular LLVM's
# Interpreter sources include ffi.h without reliably inheriting the imported
# FFI target's include directory in this LLVM revision. The NATIVE compiler
# wrappers remove these target paths before invoking the host compilers.

cmake_cross \
  -S "${SOURCES}/llvm-project/llvm" \
  -B "${LLVM_TARGET_BUILD}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POSITION_INDEPENDENT_CODE=OFF \
  -DCMAKE_C_FLAGS="-fno-pic -fno-pie" \
  -DCMAKE_CXX_FLAGS="-fno-pic -fno-pie" \
  -DCMAKE_EXE_LINKER_FLAGS="-no-pie" \
  -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=OFF \
  -DLLVM_ENABLE_PROJECTS=clang \
  -DLLVM_TARGETS_TO_BUILD="AArch64;BPF" \
  -DLLVM_HOST_TRIPLE=aarch64-linux-gnu \
  -DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-linux-gnu \
  -DLLVM_TABLEGEN="${HOST_TOOLS}/bin/llvm-tblgen" \
  -DCLANG_TABLEGEN="${HOST_TOOLS}/bin/clang-tblgen" \
  -DLLVM_NATIVE_TOOL_DIR="${HOST_TOOLS}/bin" \
  -DLLVM_CONFIG_PATH="${HOST_TOOLS}/bin/llvm-config" \
  -DLLVM_NATIVE_BUILD="${LLVM_NATIVE_BUILD}" \
  -DLLVM_USE_HOST_TOOLS=ON \
  -DCROSS_TOOLCHAIN_FLAGS_NATIVE="-DCMAKE_C_COMPILER=${HOST_CC_WRAPPER};-DCMAKE_CXX_COMPILER=${HOST_CXX_WRAPPER}" \
  -DLLVM_ENABLE_RTTI=ON \
  -DLLVM_ENABLE_EH=ON \
  -DLLVM_ENABLE_PIC=OFF \
  -DLLVM_BUILD_LLVM_DYLIB=OFF \
  -DLLVM_LINK_LLVM_DYLIB=OFF \
  -DCLANG_LINK_CLANG_DYLIB=OFF \
  -DLIBCLANG_BUILD_STATIC=ON \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_BUILD_EXAMPLES=OFF \
  -DLLVM_ENABLE_BINDINGS=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_ENABLE_LIBEDIT=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_CURL=OFF \
  -DLLVM_ENABLE_ZLIB=FORCE_ON \
  -DLLVM_ENABLE_ZSTD=FORCE_ON \
  -DLLVM_ENABLE_FFI=ON

# bpftrace consumes the exported LLVM/Clang libraries, headers and CMake
# metadata, not target-side command-line tools. Building "all" cross-compiles
# hundreds of unused binaries. Restrict the expensive phase to libraries.
cmake --build "${LLVM_TARGET_BUILD}" --parallel "${JOBS}" \
  --target llvm-libraries clang-libraries

# Install library and header components plus exported CMake package metadata.
cmake --install "${LLVM_TARGET_BUILD}" --component llvm-libraries
cmake --install "${LLVM_TARGET_BUILD}" --component llvm-headers
cmake --install "${LLVM_TARGET_BUILD}" --component clang-libraries
cmake --install "${LLVM_TARGET_BUILD}" --component clang-headers
cmake --install "${LLVM_TARGET_BUILD}" --component cmake-exports
cmake --install "${LLVM_TARGET_BUILD}" --component clang-cmake-exports

find "${PREFIX}/lib" -maxdepth 1 \
  \( -name 'libLLVM*.so*' -o -name 'libclang*.so*' \) \
  -exec file -L {} \;
