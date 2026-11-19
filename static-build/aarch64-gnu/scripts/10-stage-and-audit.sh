#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

IMAGE="${STAGING}/bpftrace-aarch64"
# The same staging directory is used for dynamic and static builds.  Remove
# the previous image first; otherwise shared objects copied by an earlier
# dynamic build would remain beside the newly-built static executable and
# make the delivered archive misleading.
rm -rf "${IMAGE}"
mkdir -p "${IMAGE}/bin" "${IMAGE}/lib" "${IMAGE}/share"

if aarch64-linux-gnu-readelf -d "${PREFIX}/bin/bpftrace" 2>/dev/null | grep -q "Shared library"; then
  echo "ERROR: bpftrace is not fully static" >&2
  aarch64-linux-gnu-readelf -d "${PREFIX}/bin/bpftrace" >&2
  exit 1
fi

install -m755 "${PREFIX}/bin/bpftrace" "${IMAGE}/bin/bpftrace"

python3 - "${PREFIX}" "${IMAGE}" <<'PY'
from pathlib import Path
import re
import shutil
import subprocess
import sys

prefix = Path(sys.argv[1])
image = Path(sys.argv[2])
binary = image / "bin" / "bpftrace"
libdir = image / "lib"

seen = set()
queue = [binary]
while queue:
    elf = queue.pop()
    # A fully static executable has no dynamic section. There is then no
    # shared-library closure to copy; the image only needs bin/bpftrace.
    proc = subprocess.run(
        ["aarch64-linux-gnu-readelf", "-d", str(elf)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0 or "Dynamic section" not in proc.stdout:
        continue
    output = proc.stdout
    for name in re.findall(r"Shared library: \[([^\]]+)\]", output):
        if name in seen:
            continue
        seen.add(name)
        candidates = list((prefix / "lib").glob(name))
        if not candidates:
            # glibc, libstdc++, libgcc and the loader belong to the base target.
            continue
        source = candidates[0].resolve()
        # Install the SONAME under the exact name recorded in DT_NEEDED.  The
        # private prefix often has only a versioned real file plus a symlink
        # (for example libz.so.1 -> libz.so.1.3.1); copying source.name would
        # lose the SONAME and leave the relocatable image unable to load it.
        target = libdir / name
        if not target.exists():
            shutil.copy2(source, target)
            queue.append(target)

print("\n".join(sorted(seen)))
PY

{
  echo "AArch64 ELF audit"
  echo "================="
find "${PREFIX}" "${IMAGE}" -type f -print0 |
    while IFS= read -r -d '' file_name; do
      # Do not classify source/header text merely because it contains the
      # string "ELF".  Also, readelf returns success for ar archives, which
      # are not themselves ELF files.  The file(1) type must start with an
      # ELF class description before we inspect its architecture.
      file_description=$(file -b "${file_name}")
      if printf '%s\n' "${file_description}" |
        grep -Eq '^ELF ([0-9]+-bit|32-bit)'; then
        printf '%s: %s\n' "${file_name}" "${file_description}"
        if ! printf '%s\n' "${file_description}" | grep -q 'ARM aarch64'; then
          echo "ERROR: non-AArch64 ELF: ${file_name}"
          exit 1
        fi
      fi
    done
} | tee "${LOGS}/aarch64-elf-audit.txt"

tar -C "${STAGING}" \
  -cJf "${STAGING}/bpftrace-aarch64.tar.xz" \
  bpftrace-aarch64

sha256sum "${STAGING}/bpftrace-aarch64.tar.xz" \
  >"${STAGING}/bpftrace-aarch64.tar.xz.sha256"

echo "Deployment image: ${IMAGE}"
echo "Archive:          ${STAGING}/bpftrace-aarch64.tar.xz"
