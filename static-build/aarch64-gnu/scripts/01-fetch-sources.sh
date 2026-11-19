#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

download()
{
  local output=$1
  local url=$2
  if [[ -s "${DOWNLOADS}/${output}" ]]; then
    echo "Using cached download: ${output}"
    return
  fi
  wget --continue --output-document="${DOWNLOADS}/${output}.part" "${url}"
  mv "${DOWNLOADS}/${output}.part" "${DOWNLOADS}/${output}"
}

extract()
{
  local archive=$1
  local destination=$2
  if [[ -e "${SOURCES}/${destination}/.extracted" ]]; then
    echo "Using extracted source: ${destination}"
    return
  fi
  mkdir -p "${SOURCES}/${destination}"
  tar -xf "${DOWNLOADS}/${archive}" \
    --strip-components=1 \
    -C "${SOURCES}/${destination}"
  touch "${SOURCES}/${destination}/.extracted"
}

download "bpftrace-${BPFTRACE_REV}.tar.gz" \
  "https://codeload.github.com/bpftrace/bpftrace/tar.gz/${BPFTRACE_REV}"
download "llvm-project-${LLVM_REV}.tar.gz" \
  "https://codeload.github.com/llvm/llvm-project/tar.gz/${LLVM_REV}"
download "bcc-${BCC_REV}.tar.gz" \
  "https://codeload.github.com/iovisor/bcc/tar.gz/${BCC_REV}"
download "libbpf-${LIBBPF_REV}.tar.gz" \
  "https://codeload.github.com/libbpf/libbpf/tar.gz/${LIBBPF_REV}"
download "blazesym-${BLAZESYM_REV}.tar.gz" \
  "https://codeload.github.com/libbpf/blazesym/tar.gz/${BLAZESYM_REV}"

download "zlib-${ZLIB_VERSION}.tar.gz" \
  "https://zlib.net/fossils/zlib-${ZLIB_VERSION}.tar.gz"
download "zstd-${ZSTD_VERSION}.tar.gz" \
  "https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/zstd-${ZSTD_VERSION}.tar.gz"
download "xz-${XZ_VERSION}.tar.gz" \
  "https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/xz-${XZ_VERSION}.tar.gz"
download "bzip2-${BZIP2_VERSION}.tar.gz" \
  "https://sourceware.org/pub/bzip2/bzip2-${BZIP2_VERSION}.tar.gz"
download "libffi-${LIBFFI_VERSION}.tar.gz" \
  "https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz"
download "elfutils-${ELFUTILS_VERSION}.tar.bz2" \
  "https://sourceware.org/elfutils/ftp/${ELFUTILS_VERSION}/elfutils-${ELFUTILS_VERSION}.tar.bz2"
download "binutils-${BINUTILS_VERSION}.tar.xz" \
  "https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VERSION}.tar.xz"
download "libpcap-${LIBPCAP_VERSION}.tar.xz" \
  "https://www.tcpdump.org/release/libpcap-${LIBPCAP_VERSION}.tar.xz"
download "cereal-${CEREAL_VERSION}.tar.gz" \
  "https://github.com/USCiLab/cereal/archive/refs/tags/v${CEREAL_VERSION}.tar.gz"

extract "bpftrace-${BPFTRACE_REV}.tar.gz" bpftrace
extract "llvm-project-${LLVM_REV}.tar.gz" llvm-project
extract "bcc-${BCC_REV}.tar.gz" bcc
extract "libbpf-${LIBBPF_REV}.tar.gz" libbpf
extract "blazesym-${BLAZESYM_REV}.tar.gz" blazesym
extract "zlib-${ZLIB_VERSION}.tar.gz" zlib
extract "zstd-${ZSTD_VERSION}.tar.gz" zstd
extract "xz-${XZ_VERSION}.tar.gz" xz
extract "bzip2-${BZIP2_VERSION}.tar.gz" bzip2
extract "libffi-${LIBFFI_VERSION}.tar.gz" libffi
extract "elfutils-${ELFUTILS_VERSION}.tar.bz2" elfutils
extract "binutils-${BINUTILS_VERSION}.tar.xz" binutils
extract "libpcap-${LIBPCAP_VERSION}.tar.xz" libpcap
extract "cereal-${CEREAL_VERSION}.tar.gz" cereal

# Fetch all Rust target/runtime source inputs now so later compilation can be
# completely offline. These are source/toolchain inputs, not old target builds.
# rsproxy avoids prolonged stalls seen when static.rust-lang.org is reached
# through slow corporate/international routes.
if command -v rustup >/dev/null; then
  if ! rustup target list --installed | grep -qx aarch64-unknown-linux-gnu; then
    RUSTUP_DIST_SERVER=https://rsproxy.cn \
    RUSTUP_UPDATE_ROOT=https://rsproxy.cn/rustup \
      timeout 600 rustup target add aarch64-unknown-linux-gnu
  fi
fi
if command -v cargo >/dev/null; then
  mkdir -p "${SOURCES}/blazesym/.cargo"
  (
    cd "${SOURCES}/blazesym"
    CARGO_REGISTRIES_CRATES_IO_INDEX='sparse+https://rsproxy.cn/index/' \
    CARGO_HTTP_TIMEOUT=600 \
      timeout 1200 cargo vendor --locked vendor > .cargo/config.toml
  )
fi

(
  cd "${DOWNLOADS}"
  find . -maxdepth 1 -type f \
    ! -name 'SHA256SUMS.generated' \
    ! -name '*.part' \
    -print0 |
    sort -z |
    xargs -0 sha256sum > SHA256SUMS.generated.tmp
  mv SHA256SUMS.generated.tmp SHA256SUMS.generated
)

echo "Sources downloaded, extracted and recorded in ${DOWNLOADS}/SHA256SUMS.generated"
