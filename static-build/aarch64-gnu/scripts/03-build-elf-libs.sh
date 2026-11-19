#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

(
  cd "${SOURCES}/elfutils"
  if [[ ! -x ./configure ]]; then
    autoreconf -fi
  fi
  ./configure \
    --build=x86_64-pc-linux-gnu \
    --host=aarch64-linux-gnu \
    --prefix="${PREFIX}" \
    --libdir="${PREFIX}/lib" \
    --disable-debuginfod \
    --disable-libdebuginfod \
    --disable-nls \
    --disable-werror \
    --enable-maintainer-mode \
    --without-libiconv-prefix \
    CPPFLAGS="-I${PREFIX}/include" \
    LDFLAGS="-L${PREFIX}/lib -Wl,-rpath-link,${PREFIX}/lib" \
    PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR}"
  # elfutils builds a small target helper (i386_gendis) and executes it to
  # generate source tables. Run target helpers through user-mode QEMU while
  # preserving the strict three-job build limit.
  make -j"${JOBS}" \
    GENDIS_ENV="qemu-aarch64-static -L /usr/aarch64-linux-gnu"
  make install
)

mkdir -p "${BUILD}/binutils"
(
  cd "${BUILD}/binutils"
  "${SOURCES}/binutils/configure" \
    --build=x86_64-pc-linux-gnu \
    --host=aarch64-linux-gnu \
    --target=aarch64-linux-gnu \
    --prefix="${PREFIX}" \
    --libdir="${PREFIX}/lib" \
    --enable-shared \
    --enable-static \
    --enable-install-libiberty \
    --disable-werror \
    --disable-nls \
    --disable-gdb \
    --disable-gdbserver \
    --disable-gprofng \
    --disable-gold \
    --disable-sim \
    --disable-readline \
    --with-system-zlib \
    --with-zstd \
    CPPFLAGS="-I${PREFIX}/include" \
    LDFLAGS="-L${PREFIX}/lib -Wl,-rpath-link,${PREFIX}/lib"
  make -j"${JOBS}"
  make install
)

(
  cd "${SOURCES}/libpcap"
  ./configure \
    --build=x86_64-pc-linux-gnu \
    --host=aarch64-linux-gnu \
    --prefix="${PREFIX}" \
    --libdir="${PREFIX}/lib" \
    --enable-shared \
    --enable-static \
    --disable-dbus \
    --disable-bluetooth \
    --disable-usb \
    --disable-netmap \
    --without-libnl \
    CPPFLAGS="-I${PREFIX}/include" \
    LDFLAGS="-L${PREFIX}/lib"
  make -j"${JOBS}"
  make install
)

echo "ELF, binutils and pcap libraries installed under ${PREFIX}"
