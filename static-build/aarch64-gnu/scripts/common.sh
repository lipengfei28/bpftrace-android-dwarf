#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)

# shellcheck source=../versions.env
source "${ROOT}/versions.env"

DOWNLOADS="${ROOT}/downloads"
SOURCES="${ROOT}/sources"
BUILD="${ROOT}/build"
HOST_TOOLS="${ROOT}/host-tools"
PREFIX="${ROOT}/prefix"
STAGING="${ROOT}/staging"
LOGS="${ROOT}/logs"
TOOLCHAIN="${ROOT}/toolchains/aarch64-linux-gnu.cmake"
# Keep the complete build, including nested CMake/Make projects, within the
# requested three-way parallelism limit.
JOBS=3

export AARCH64_PREFIX="${PREFIX}"
# CMake's nested LLVM native build does not receive the outer
# `cmake --build --parallel` option.  Propagate the limit through the
# environment. The outer Ninja already spends one of its three slots on this
# nested build, so use one nested job to keep the total at three rather than
# allowing three nested jobs in addition to the outer jobs.
export CMAKE_BUILD_PARALLEL_LEVEL=1
# blazesym is built by Cargo rather than CMake/Make; keep its rustc jobs in
# line with the same global limit.
export CARGO_BUILD_JOBS="${JOBS}"
# Never prepend target/bin to PATH: build helpers must execute on x86_64, and
# target programs such as an AArch64 xz/llvm-config cannot run on the host.
export PKG_CONFIG_SYSROOT_DIR=
export PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig"
export PKG_CONFIG_PATH=
export CPATH="${PREFIX}/include"
export LIBRARY_PATH="${PREFIX}/lib"

export CC=aarch64-linux-gnu-gcc
export CXX=aarch64-linux-gnu-g++
export AR=aarch64-linux-gnu-ar
export RANLIB=aarch64-linux-gnu-ranlib
export STRIP=aarch64-linux-gnu-strip
export NM=aarch64-linux-gnu-nm
export OBJCOPY=aarch64-linux-gnu-objcopy
export OBJDUMP=aarch64-linux-gnu-objdump
export READELF=aarch64-linux-gnu-readelf

mkdir -p \
  "${DOWNLOADS}" "${SOURCES}" "${BUILD}" "${HOST_TOOLS}" \
  "${PREFIX}"/{bin,include,lib,share} "${STAGING}" "${LOGS}"

run_logged()
{
  local name=$1
  shift
  echo "[$(date -Is)] START ${name}"
  "$@" 2>&1 | tee "${LOGS}/${name}.log"
  echo "[$(date -Is)] DONE  ${name}"
}

cmake_cross()
{
  cmake -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    "$@"
}

build_install_cmake()
{
  local name=$1
  local src=$2
  shift 2
  local bld="${BUILD}/${name}"

  cmake_cross -S "${src}" -B "${bld}" "$@"
  cmake --build "${bld}" --parallel "${JOBS}"
  cmake --install "${bld}"
}

require_file()
{
  test -e "$1" || {
    echo "Required file is missing: $1" >&2
    exit 1
  }
}

assert_aarch64_elf()
{
  local file=$1
  if ! file -L "${file}" | grep -q 'ARM aarch64'; then
    echo "Not an AArch64 ELF file: ${file}" >&2
    file -L "${file}" >&2 || true
    exit 1
  fi
}
