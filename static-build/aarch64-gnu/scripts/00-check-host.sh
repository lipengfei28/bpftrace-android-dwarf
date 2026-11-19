#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

required=(
  aarch64-linux-gnu-gcc
  aarch64-linux-gnu-g++
  aarch64-linux-gnu-ar
  aarch64-linux-gnu-ranlib
  aarch64-linux-gnu-readelf
  cmake
  ninja
  make
  python3
  bison
  flex
  pkg-config
  autoconf
  automake
  libtoolize
  patch
  tar
  wget
  sha256sum
)

for tool in "${required[@]}"; do
  command -v "${tool}" >/dev/null || {
    echo "Missing host tool: ${tool}" >&2
    exit 1
  }
done

cat >"${BUILD}/toolchain-smoke.cpp" <<'EOF'
#include <span>
#include <vector>
int main()
{
  std::vector<int> values{1};
  return std::span<int>(values).size() != 1;
}
EOF

aarch64-linux-gnu-g++ -std=c++20 \
  "${BUILD}/toolchain-smoke.cpp" \
  -o "${BUILD}/toolchain-smoke"
assert_aarch64_elf "${BUILD}/toolchain-smoke"

cat <<EOF
Cross toolchain check passed.
  compiler: $(aarch64-linux-gnu-gcc --version | head -1)
  prefix:   ${PREFIX}
  jobs:     ${JOBS}
EOF

