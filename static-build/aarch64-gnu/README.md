# bpftrace AArch64 GNU/Linux full source cross build

This tree builds bpftrace and its target-side third-party libraries from clean,
pinned source archives with `aarch64-linux-gnu-gcc/g++`. Nothing is installed
under `/usr`, `/usr/local`, or `/usr/aarch64-linux-gnu`.

## Output directories

- `prefix/`: private development prefix containing target headers and libraries
- `staging/bpftrace-aarch64/`: relocatable deployment tree
- `staging/bpftrace-aarch64.tar.xz`: deployment archive
- `logs/`: configure/build/audit records

All builds use exactly three parallel jobs (`-j3`). `scripts/common.sh`
propagates this limit to nested CMake builds (including LLVM's native helper
build) with `CMAKE_BUILD_PARALLEL_LEVEL=1` (the nested build occupies one of
the outer build's three slots), and to the Rust build with
`CARGO_BUILD_JOBS=3`.

## Run

```bash
# Run from this directory. This downloads all pinned sources, builds every
# dependency with the AArch64 cross toolchain, installs into prefix/, and
# creates the final static deployment archive under staging/.
./scripts/build-all.sh
```

The command is resumable: downloads, extracted sources, CMake build trees, and
installed artifacts are reused when they are already present. It does not
install files into `/usr` or modify the host system. The package source trees
are kept pristine; cross-build-only adjustments are supplied by the scripts,
an external CMake include, and the static C++ link wrapper.

The only target components reused from the installed cross toolchain are the
toolchain foundation: glibc, libgcc, libstdc++, the dynamic loader, and Linux
UAPI headers. All bpftrace-related libraries are rebuilt into `prefix/`.

The default build enables libdw, BFD/opcodes disassembly, libpcap skb output,
and blazesym. systemd notification, manuals, and target-side tests are disabled;
they are not required by the bpftrace runtime.

If resuming a build made by an older version of the scripts, remove stale
LLVM native-build directories before rerunning the LLVM step:

```bash
rm -rf build/llvm-aarch64/NATIVE build/llvm-aarch64/NATIVE-stamps \
       build/llvm-native-x86_64 build/llvm-native-x86_64-stamps
./scripts/06-build-llvm-aarch64.sh
```

The native LLVM helpers run on the x86_64 build host; they must not be
configured with `aarch64-linux-gnu-g++`. The command above is only needed when
the existing build tree was configured with the old native-build path or
compiler settings.
