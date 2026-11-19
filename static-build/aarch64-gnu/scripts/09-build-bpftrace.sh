#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# Keep the static configuration separate from the previous shared build. CMake
# caches absolute results of find_library(), so reusing the old build directory
# would continue selecting libbfd.so/libbcc_bpf.so even after changing the
# suffix and link mode.
BPFTRACE_BUILD="${BUILD}/${BPFTRACE_BUILD_NAME:-bpftrace-static}"
# An existing bpftrace working tree can be supplied without copying, patching,
# resetting, or otherwise changing it.  CMake is always configured out of tree.
STATIC_BPFTRACE_SRC="${BPFTRACE_SOURCE_DIR:-${SOURCES}/bpftrace}"
BPFTRACE_BUILD_TYPE="${BPFTRACE_BUILD_TYPE:-Release}"
BPFTRACE_EXTRA_C_FLAGS="${BPFTRACE_EXTRA_C_FLAGS:--fno-pie}"
BPFTRACE_EXTRA_CXX_FLAGS="${BPFTRACE_EXTRA_CXX_FLAGS:--fno-pie}"
BPFTRACE_LLVM_DIR="${BPFTRACE_LLVM_DIR:-${PREFIX}/lib/cmake/llvm}"
BPFTRACE_CLANG_DIR="${BPFTRACE_CLANG_DIR:-${PREFIX}/lib/cmake/clang}"
BPFTRACE_BUILD_TARGET="${BPFTRACE_BUILD_TARGET:-bpftrace}"
STATIC_CMAKE_INCLUDE="${BUILD}/bpftrace-static-dependencies.cmake"
STATIC_CXX_WRAPPER="${BUILD}/aarch64-static-cxx"
STATIC_TOOLCHAIN="${BUILD}/aarch64-static-toolchain.cmake"

if [[ ! -f "${STATIC_BPFTRACE_SRC}/CMakeLists.txt" ]]; then
  echo "Invalid bpftrace source directory: ${STATIC_BPFTRACE_SRC}" >&2
  exit 1
fi

# Record all source content outside Git's private metadata.  This catches
# changes to tracked files, untracked source files, generated files, and
# symlink targets without changing or refreshing the source repository index.
source_manifest()
{
  local source_dir=$1
  (
    cd "${source_dir}"
    find . \
      -path './.git' -prune -o \
      -path '*/.git' -prune -o \
      -path './build*' -prune -o \
      -path './tests/data/evidence' -prune -o \
      -type f -print0 |
      LC_ALL=C sort -z |
      xargs -0 sha256sum
    find . \
      -path './.git' -prune -o \
      -path '*/.git' -prune -o \
      -path './build*' -prune -o \
      -path './tests/data/evidence' -prune -o \
      -type l -printf 'SYMLINK %p -> %l\n' |
      LC_ALL=C sort
  )
}

SOURCE_MANIFEST_BEFORE="${LOGS}/${BPFTRACE_BUILD_NAME:-bpftrace-static}-source-before.sha256"
SOURCE_MANIFEST_AFTER="${LOGS}/${BPFTRACE_BUILD_NAME:-bpftrace-static}-source-after.sha256"
source_manifest "${STATIC_BPFTRACE_SRC}" >"${SOURCE_MANIFEST_BEFORE}"

verify_source_unchanged()
{
  local status=$?
  source_manifest "${STATIC_BPFTRACE_SRC}" >"${SOURCE_MANIFEST_AFTER}"
  if ! cmp -s "${SOURCE_MANIFEST_BEFORE}" "${SOURCE_MANIFEST_AFTER}"; then
    echo "ERROR: bpftrace source content changed during the build:" >&2
    diff -u "${SOURCE_MANIFEST_BEFORE}" "${SOURCE_MANIFEST_AFTER}" >&2 || true
    exit 1
  fi
  echo "Verified unchanged bpftrace source: ${STATIC_BPFTRACE_SRC}"
  return "${status}"
}
trap verify_source_unchanged EXIT

# Keep the link-state workaround in the build wrapper rather than modifying
# bpftrace's source CMakeLists.txt. The wrapper is used by CMake as the C++
# compiler and only changes linker arguments; compile invocations are passed
# through unchanged.
install -m 0755 "${SCRIPT_DIR}/aarch64-static-cxx" "${STATIC_CXX_WRAPPER}"
cat >"${STATIC_TOOLCHAIN}" <<EOF
include("${TOOLCHAIN}")
set(CMAKE_CXX_COMPILER "${STATIC_CXX_WRAPPER}" CACHE FILEPATH "" FORCE)
EOF

# elfutils keeps libebl as an internal (noinst) archive, although bpftrace's
# static libdw link needs it as a separate archive. Export the archive built
# by the source tree into the private prefix; do not use a host/system copy.
install -m 0644 "${SOURCES}/elfutils/libebl/libebl.a" \
  "${PREFIX}/lib/libebl.a"

# Component installs in this LLVM revision do not pull the libclang
# subcomponent when invoked from the top-level install driver. Copy the
# freshly-built static archives explicitly so the private prefix cannot retain
# the previous PIC archives from the shared build.
find "${BUILD}/llvm-aarch64-static-nopic/lib" -maxdepth 1 -type f \
  -name '*.a' -exec install -m 0644 {} "${PREFIX}/lib/" \;

# LLVM's exported static targets carry a dependency on zstd::libzstd_shared,
# but the bpftrace project does not itself call find_package(zstd). Load the
# source-built zstd package before bpftrace declares its targets.
cat >"${STATIC_CMAKE_INCLUDE}" <<'EOF'
# This preload runs before bpftrace sets STATIC_LINKING's search suffix. Set
# the suffix and zlib archive explicitly before importing Clang/LLVM targets,
# otherwise a clean CMake cache may bind ZLIB::ZLIB to libz.so.
set(CMAKE_FIND_LIBRARY_SUFFIXES ".a")
set(ZLIB_LIBRARY "${AARCH64_PREFIX}/lib/libz.a" CACHE FILEPATH "" FORCE)
set(ZLIB_LIBRARY_RELEASE "${AARCH64_PREFIX}/lib/libz.a"
  CACHE FILEPATH "" FORCE)
set(ZLIB_LIBRARY_DEBUG "${AARCH64_PREFIX}/lib/libz.a"
  CACHE FILEPATH "" FORCE)
set(ZLIB_LIBRARIES "${AARCH64_PREFIX}/lib/libz.a" CACHE STRING "" FORCE)
find_package(ZLIB REQUIRED)
find_package(zstd CONFIG REQUIRED)
# The include is loaded immediately after project() and before bpftrace calls
# find_package(Clang). Resolve Clang here so the imported libclang target can
# carry the dependency that the static archive needs.
find_package(Clang CONFIG REQUIRED)
# LLVM 23's exported target names the zstd dependency "shared" even when
# LLVM itself is being consumed as static archives. Point that imported
# target at the source-built static archive so no libzstd.so enters the link.
set_property(TARGET zstd::libzstd_shared PROPERTY IMPORTED_LOCATION_RELEASE
  "${AARCH64_PREFIX}/lib/libzstd.a")
set_property(TARGET zstd::libzstd_shared PROPERTY IMPORTED_LOCATION
  "${AARCH64_PREFIX}/lib/libzstd.a")

# bpftrace's static branch uses the historical target name
# `libclang_static`, while current Clang exports only `libclang`.
if(NOT TARGET libclang_static)
  add_library(libclang_static STATIC IMPORTED GLOBAL)
  set_target_properties(libclang_static PROPERTIES
    IMPORTED_LOCATION "${AARCH64_PREFIX}/lib/libclang.a"
    INTERFACE_INCLUDE_DIRECTORIES "${AARCH64_PREFIX}/include"
    INTERFACE_LINK_LIBRARIES "clangIndex;LLVMABI")
endif()
EOF

# blazesym-c is a source-built static archive. Its optional xz feature leaves
# liblzma as a consumer-side dependency, so provide it explicitly rather than
# relying on a transitive shared-library lookup.
cmake_cross \
  -S "${STATIC_BPFTRACE_SRC}" \
  -B "${BPFTRACE_BUILD}" \
  "-DCMAKE_TOOLCHAIN_FILE=${STATIC_TOOLCHAIN}" \
  "-DCMAKE_BUILD_TYPE=${BPFTRACE_BUILD_TYPE}" \
  -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=OFF \
  -DCMAKE_SKIP_RPATH=ON \
  -DSTATIC_LINKING=ON \
  "-DCMAKE_CXX_COMPILER=${STATIC_CXX_WRAPPER}" \
  "-DCMAKE_EXE_LINKER_FLAGS=-static -fno-pie -no-pie" \
  "-DCMAKE_C_FLAGS=${BPFTRACE_EXTRA_C_FLAGS}" \
  "-DCMAKE_CXX_FLAGS=${BPFTRACE_EXTRA_CXX_FLAGS}" \
  -DCMAKE_FIND_LIBRARY_SUFFIXES=.a \
  -DCMAKE_LINK_SEARCH_START_STATIC=ON \
  -DCMAKE_LINK_SEARCH_END_STATIC=ON \
  -DCMAKE_PROJECT_INCLUDE="${STATIC_CMAKE_INCLUDE}" \
  -DCMAKE_PREFIX_PATH="${PREFIX}" \
  -DLLVM_REQUESTED_VERSION=23 \
  "-DLLVM_DIR=${BPFTRACE_LLVM_DIR}" \
  "-DClang_DIR=${BPFTRACE_CLANG_DIR}" \
  -DLLVM_LINK_LLVM_DYLIB=OFF \
  "-DLIBEBL_LIBRARIES=${PREFIX}/lib/libebl.a" \
  -DUSE_SYSTEM_LIBBPF=ON \
  "-DLIBBLAZESYM_LIBRARIES=${PREFIX}/lib/libblazesym_c.a;${PREFIX}/lib/liblzma.a" \
  -DBUILD_TESTING=OFF \
  -DENABLE_MAN=OFF \
  -DENABLE_SKB_OUTPUT=ON \
  -DENABLE_SYSTEMD=OFF

# Build the requested deliverable rather than the default "all" target.
# Current bpftrace trees can also contain optional executables such as the AOT
# runtime; those are not needed to produce or deploy the bpftrace CLI.
cmake --build "${BPFTRACE_BUILD}" \
  --target "${BPFTRACE_BUILD_TARGET}" \
  --parallel "${JOBS}"

if [[ "${BPFTRACE_BUILD_TARGET}" == bpftrace ]]; then
  # The top-level install target also installs optional executables (for
  # example bpftrace-aotrt) even when only the CLI target was requested.
  # Install the requested deliverable directly from the out-of-tree build.
  install -m 0755 "${BPFTRACE_BUILD}/src/bpftrace" \
    "${PREFIX}/bin/bpftrace"
  if [[ -f "${STATIC_BPFTRACE_SRC}/scripts/bash-completion/bpftrace" ]]; then
    install -d "${PREFIX}/share/bash-completion/completions"
    install -m 0644 \
      "${STATIC_BPFTRACE_SRC}/scripts/bash-completion/bpftrace" \
      "${PREFIX}/share/bash-completion/completions/bpftrace"
  fi
else
  cmake --install "${BPFTRACE_BUILD}"
fi

assert_aarch64_elf "${PREFIX}/bin/bpftrace"
aarch64-linux-gnu-readelf -d "${PREFIX}/bin/bpftrace" \
  >"${LOGS}/bpftrace-dynamic-section.txt"
