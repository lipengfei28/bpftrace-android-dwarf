#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

if [[ ! -e "${PREFIX}/lib/libz.so" ]]; then
  build_install_cmake zlib "${SOURCES}/zlib" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DZLIB_BUILD_EXAMPLES=OFF
fi

if [[ ! -e "${PREFIX}/lib/libzstd.so" ]]; then
  build_install_cmake zstd "${SOURCES}/zstd/build/cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DZSTD_BUILD_PROGRAMS=OFF \
    -DZSTD_BUILD_TESTS=OFF \
    -DZSTD_BUILD_CONTRIB=OFF \
    -DZSTD_BUILD_SHARED=ON \
    -DZSTD_BUILD_STATIC=ON
fi

if [[ ! -e "${PREFIX}/lib/liblzma.so" ]]; then
  (
    cd "${SOURCES}/xz"
    ./configure \
      --build=x86_64-pc-linux-gnu \
      --host=aarch64-linux-gnu \
      --prefix="${PREFIX}" \
      --libdir="${PREFIX}/lib" \
      --enable-shared \
      --enable-static \
      --disable-doc \
      --disable-nls \
      CPPFLAGS="-I${PREFIX}/include" \
      LDFLAGS="-L${PREFIX}/lib"
    make -j"${JOBS}"
    make install
  )
fi

if [[ ! -e "${PREFIX}/lib/libbz2.a" ]]; then
  (
    cd "${SOURCES}/bzip2"
    # The upstream default "all" target executes the freshly built bzip2
    # program, which is impossible during a cross build. Build and install the
    # target library/header directly without running an AArch64 executable.
    make -j"${JOBS}" libbz2.a \
      CC="${CC}" AR="${AR}" RANLIB="${RANLIB}" \
      CFLAGS="-O2 -fPIC -Wall -Winline"
    install -m644 libbz2.a "${PREFIX}/lib/libbz2.a"
    install -m644 bzlib.h "${PREFIX}/include/bzlib.h"
  )
fi

if [[ ! -e "${PREFIX}/lib/libffi.so" ]]; then
  (
    cd "${SOURCES}/libffi"
    ./configure \
      --build=x86_64-pc-linux-gnu \
      --host=aarch64-linux-gnu \
      --prefix="${PREFIX}" \
      --libdir="${PREFIX}/lib" \
      --enable-shared \
      --enable-static \
      --disable-docs \
      --disable-multi-os-directory \
      CPPFLAGS="-I${PREFIX}/include" \
      LDFLAGS="-L${PREFIX}/lib"
    make -j"${JOBS}"
    make install
  )
fi

mkdir -p "${PREFIX}/include"
cp -a "${SOURCES}/cereal/include/cereal" "${PREFIX}/include/"

echo "Base libraries installed under ${PREFIX}"
