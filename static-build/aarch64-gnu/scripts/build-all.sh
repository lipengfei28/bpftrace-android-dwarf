#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

steps=(
  00-check-host.sh
  01-fetch-sources.sh
  02-build-base-libs.sh
  03-build-elf-libs.sh
  04-build-libbpf.sh
  05-build-llvm-host-tools.sh
  06-build-llvm-aarch64.sh
  07-build-bcc.sh
  08-build-blazesym.sh
  09-build-bpftrace.sh
  10-stage-and-audit.sh
)

for step in "${steps[@]}"; do
  echo
  echo "================================================================"
  echo "Running ${step} with build parallelism fixed at -j3"
  echo "================================================================"
  "${SCRIPT_DIR}/${step}"
done
