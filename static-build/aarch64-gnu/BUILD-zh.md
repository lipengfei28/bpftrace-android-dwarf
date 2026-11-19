# arm64 完全静态构建 bpftrace

从源码交叉编译出 aarch64 完全静态的 bpftrace，产物可以直接推到 Android 设备运行。

整套脚本从零开始编译所有依赖（LLVM、bcc、libbpf、elfutils、blazesym、zlib 等），
不使用系统里的任何 aarch64 库。

## 为什么需要完全静态

Android 上跑的 bpftrace 必须满足：

| 要求 | 原因 |
|------|------|
| 静态链接 | 设备上找不到构建机用的 glibc/LLVM 共享库 |
| 无 `PT_INTERP` | 不依赖 `/system/bin/linker64` |
| 无 `DT_NEEDED` | 不依赖任何 `.so` |

`ko_dwarf_env.sh` 还要求这一点更严格：它用 chroot 改变根目录，动态链接的程序
在那里面无法执行（`/system/bin/sh` 就会失败），只有静态二进制能当入口。

## 前置条件

Host 需要一套 aarch64 交叉工具链：

```bash
sudo apt install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
```

以及构建工具：

```text
cmake ninja make python3 bison flex pkg-config autoconf automake
libtoolize patch tar wget sha256sum
```

`scripts/00-check-host.sh` 会逐项检查，缺一个就退出。

## 用法

```bash
cd static-build/aarch64-gnu

# 全流程：下载 → 编译所有依赖 → 编译 bpftrace → 审计
./scripts/build-all.sh
```

可断点续跑。已下载的源码、已编译的库、已有的 CMake 构建树都会被复用。

产物：

```text
prefix/bin/bpftrace                      最终二进制
staging/bpftrace-aarch64/                可重定位部署树
staging/bpftrace-aarch64.tar.xz          部署归档
logs/                                    configure/build/audit 记录
```

## 只重新编译 bpftrace

依赖已经编好时，不必重跑全流程：

```bash
cd static-build/aarch64-gnu
AARCH64_PREFIX="$PWD/prefix" \
BPFTRACE_SOURCE_DIR=/path/to/bpftrace \
BPFTRACE_BUILD_NAME=my-build \
  ./scripts/09-build-bpftrace.sh
```

- `AARCH64_PREFIX` 必须设置，否则 CMake 重新生成时会失败
- `BPFTRACE_SOURCE_DIR` 可以指向任意 bpftrace 工作树，脚本不会修改它
  （只做 out-of-tree 配置）
- 不要运行 `clean.sh` 之类的东西，会失去增量缓存

## 验证产物

```bash
BIN=prefix/bin/bpftrace

file "$BIN"                                    # 应为 ARM aarch64, statically linked
readelf -h "$BIN" | grep -E 'Class|Machine'    # ELF64 / AArch64
! readelf -l "$BIN" | grep -q PT_INTERP        # 不应有解释器
readelf -d "$BIN"                              # 应显示 no dynamic section
! readelf -d "$BIN" | grep -Eq 'NEEDED|RPATH|RUNPATH'
"$BIN" --version
sha256sum "$BIN"
```

`scripts/10-stage-and-audit.sh` 会自动跑这些检查。

## 推到设备

```bash
adb -s <serial> push prefix/bin/bpftrace /data/local/tmp/bpftrace-fl
adb -s <serial> shell chmod 755 /data/local/tmp/bpftrace-fl

# 核对哈希，避免用到设备上的旧文件
HOST_MD5=$(md5sum prefix/bin/bpftrace | awk '{print $1}')
DEV_MD5=$(adb -s <serial> shell md5sum /data/local/tmp/bpftrace-fl | tr -d '\r' | awk '{print $1}')
test "$HOST_MD5" = "$DEV_MD5" && echo OK
```

## 脚本说明

| 脚本 | 作用 |
|------|------|
| `build-all.sh` | 按顺序跑下面所有步骤 |
| `00-check-host.sh` | 检查交叉工具链和构建工具 |
| `01-fetch-sources.sh` | 下载所有依赖源码，按 `versions.env` 校验 SHA256 |
| `02-build-base-libs.sh` | zlib、zstd、xz、bzip2、libffi、cereal |
| `03-build-elf-libs.sh` | elfutils、binutils、libpcap |
| `04-build-libbpf.sh` | libbpf |
| `05-build-llvm-host-tools.sh` | 给 LLVM 交叉编译用的 host 工具（TableGen 等） |
| `06-build-llvm-aarch64.sh` | LLVM（aarch64） |
| `07-build-bcc.sh` | bcc |
| `08-build-blazesym.sh` | blazesym（Rust） |
| `09-build-bpftrace.sh` | bpftrace 本体 |
| `10-stage-and-audit.sh` | 打包并审计产物 |
| `aarch64-static-cxx` | 链接 wrapper，见下 |

## aarch64-static-cxx 的作用

上游 `STATIC_LINKING` 分支会为少数系统库插入 `-Wl,-Bdynamic`，把链接状态切回
动态。这个 wrapper 在源码树之外过滤掉该参数，并在最终状态强制 `-Wl,-Bstatic`。

**不要为此修改 upstream 的 `src/CMakeLists.txt`。**

## 并行度

所有构建固定 `-j3`。`common.sh` 通过 `CMAKE_BUILD_PARALLEL_LEVEL=1` 和
`CARGO_BUILD_JOBS=3` 把这个限制传递到嵌套的 CMake（含 LLVM 的 native 工具构建）
和 Rust 构建，保证总并行度不超过 3。

改并行度需要同时改 `common.sh` 里的 `JOBS` 和上述两个环境变量。

## 版本固定

`versions.env` 记录所有依赖的 commit SHA 和版本号。注释里写明：
更新 URL 和 SHA256SUMS 必须同时进行，不允许把固定 revision 换成 branch。

## 已知问题

- 构建耗时很长（LLVM 占大头），需要足够磁盘空间（数 GB）
- 交叉编译的 `llvm-config` 这类工具不能在 host 上直接执行，脚本已处理
  （`PKG_CONFIG_SYSROOT_DIR` 置空、不把 target/bin 加进 PATH）
