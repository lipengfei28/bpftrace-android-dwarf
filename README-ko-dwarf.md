# Android 内核模块（.ko）DWARF 源码行 kprobe

在 Android 上让 `kprobe@FILE:LINE` 支持内核模块，用于列出模块函数的源码行、
attach 到模块内的具体源码行。

主内核不需要这个脚本，直接 `--debuginfo` 即可；本文只解决模块部分。

## 为什么需要额外处理

libdwfl 查找模块 ELF 的路径写死在 elfutils 源码里：

```c
/* libdwfl/linux-kernel-modules.c:797-800 */
/* Do "find /lib/modules/`uname -r` -name MODULE_NAME.ko".  */
asprintf (&modulesdir[0], MODULEDIRFMT, release);   /* "/lib/modules/%s" */
```

Android 上 `/lib` 根本不存在，`/` 是只读 erofs，无法创建：

```shell
$ ls -ld /lib
ls: /lib: No such file or directory
$ mount | grep ' / '
/dev/block/dm-9 on / type erofs (ro,seclabel,relatime,...)
$ su 0 mkdir /lib
mkdir: '/lib': Read-only file system
```

`--debuginfo` 不能补救。它只作用于主内核镜像和 debug 文件
（`try_kernel_name`，`linux-kernel-modules.c:99-118`），模块 ELF 的查找完全
不经过这条路径。

## 解决方案

用 overlayfs 造一个可写的 `/`，把 `.ko` 放到 elfutils 期望的位置，再 chroot
进去运行 bpftrace。

```
Read-only / (erofs)
      |
      | overlayfs (upperdir on tmpfs)
      v
 Writable /mnt/ovlroot/newroot
      |
      +-- /lib/modules/<release>/kernel/*.ko   <- 真实的 .ko 文件
      +-- /sys, /proc, /dev                    <- rbind 自真实系统
      |
      v
   chroot -> 静态链接的 bpftrace
```

## 前置条件

| 项 | 要求 |
|----|------|
| 设备 root | 需要，用于挂载和 chroot |
| 内核 overlayfs | `CONFIG_OVERLAY_FS=y` |
| bpftrace | 必须**完全静态链接**，见下方说明 |
| vmlinux | 与运行内核匹配，带 DWARF |
| 模块 .ko | 带 DWARF（多数 Android 发行版镜像里的 `.ko` 都带） |

`bpftrace` 必须静态链接，是因为 chroot 后 `/system/bin/sh` 无法执行（依赖
动态 linker），只能用静态二进制当 chroot 的入口。

## 快速开始

三份文件：`ko_dwarf_env.sh`（主脚本）、`gen_traceable.awk`（生成函数清单）。

### 步骤 1：推到设备

```bash
adb -s <serial> push ko_dwarf_env.sh  /data/local/tmp/
adb -s <serial> push gen_traceable.awk /data/local/tmp/
adb -s <serial> push <你的静态 bpftrace> /data/local/tmp/bpftrace-fl
adb -s <serial> shell chmod 755 /data/local/tmp/bpftrace-fl
```

### 步骤 2：准备 traceable functions 文件

```bash
adb -s <serial> shell 'su 0 sh -c "
  awk -f /data/local/tmp/gen_traceable.awk /proc/kallsyms | sort -u \
    > /data/local/tmp/traceable.txt
  wc -l /data/local/tmp/traceable.txt
"'
```

预期输出类似 `194187 /data/local/tmp/traceable.txt`。

**这一步不能省，也不能用 `awk '{print $3}'` 简化。** 原因见下方「两个必踩的坑」。

### 步骤 3：准备 vmlinux

设备上需要一份与运行内核匹配、带 DWARF 的 vmlinux，并让它以
`vmlinux-<uname -r>` 的名字出现在 debuginfo 目录里。

```bash
# 先确认运行内核的 build-id
adb -s <serial> shell 'su 0 cat /sys/kernel/notes | od -An -tx1 -v \
  | tr -d " \n" | tail -c 40; echo'

# 确认手中 vmlinux 的 build-id
readelf -n /path/to/vmlinux | grep 'Build ID'
```

两者必须一致。然后：

```bash
adb -s <serial> push /path/to/vmlinux /data/local/tmp/vmlinux
adb -s <serial> shell 'su 0 sh -c "
  echo 0 > /proc/sys/kernel/kptr_restrict
  mkdir -p /data/local/tmp/dbg
  ln -sfn /data/local/tmp/vmlinux /data/local/tmp/dbg/vmlinux-$(uname -r)
"'
```

`echo 0 > /proc/sys/kernel/kptr_restrict` 是必须的，否则 `/proc/kallsyms`
里的地址全是 0，libdwfl 算不出内核地址范围，DWARF 加载直接失败。重启后恢复。

### 步骤 4：运行

```bash
# 列出模块函数的全部源码行
adb -s <serial> shell 'su 0 unshare -m sh /data/local/tmp/ko_dwarf_env.sh \
  -- -l "kprobe:zs_malloc@*"'

# attach 到模块内的某个源码行
adb -s <serial> shell 'su 0 unshare -m sh /data/local/tmp/ko_dwarf_env.sh \
  -- -e "kprobe@/proc/self/cwd/common/mm/zsmalloc.c:332 { @hits = count(); }"'
```

**注意脚本参数和 bpftrace 参数之间的 `--` 分隔符。** 没有它，bpftrace 的
`-l` 会被脚本自己的 `getopts` 吃掉，报 `unknown option: -l`。

脚本选项（都在 `--` 之前）：

```
-d DIR   debuginfo 目录（默认 /data/local/tmp/dbg）
-B PATH  bpftrace 路径（默认 /data/local/tmp/bpftrace-fl）
-T PATH  traceable 文件（默认 /data/local/tmp/traceable.txt）
-h       帮助
```

## 实测结果

设备 `6.12.69-android16-6-4k`，build-id `<image-build-id>`，与 vmlinux 一致。

列出模块函数源码行：

```shell
$ su 0 unshare -m sh /data/local/tmp/ko_dwarf_env.sh -- -l 'kprobe:zs_malloc@*'
modules staged: 482
kprobe@/proc/self/cwd/common/mm/zsmalloc.c:332
kprobe@/proc/self/cwd/common/mm/zsmalloc.c:338
kprobe@/proc/self/cwd/common/mm/zsmalloc.c:450
...
```

attach 并命中：

```shell
$ su 0 unshare -m sh /data/local/tmp/ko_dwarf_env.sh \
    -- -e 'kprobe@/proc/self/cwd/common/mm/zsmalloc.c:332 { @hits = count(); }'
Attached 2 probes
@hits: 753710
```

用模块限定的函数名做对照：

```shell
$ ... -- -e 'kprobe:zsmalloc:zs_malloc { @by_name = count(); }'
Attached 2 probes
@by_name: 92167
```

压力负载用的是
`app_launch_swipe_test.py`：

```bash
python3 app_launch_swipe_test.py --serial <serial> --count 8 \
  --settle-seconds 1.5 --swipe-direction up
```

## 两个必踩的坑

### 坑 1：traceable 文件必须带模块后缀

`/proc/kallsyms` 里模块符号长这样：

```
ffffffe2fc8aee44 t zram_submit_bio	[zram]
```

模块名在第 4 列。如果只取 `$3`：

```awk
$2 ~ /^[TtWw]$/ { print $3 }        # 错误：丢掉模块归属
```

结果是 134554 行，`grep zram` 为 **0**。所有模块符号都被当成 vmlinux 的，
`is_traceable()` 查不到，`-l 'kprobe:zs_malloc@*'` 静默返回空。

正确做法（`gen_traceable.awk`）：

```awk
$2 ~ /^[TtWw]$/ {
  if ($4 ~ /^\[/) {
    m = $4; gsub(/[\[\]]/, "", m); print $3 " [" m "]"
  } else {
    print $3
  }
}
```

输出 194187 行，其中 zram 相关 378 条，格式是 `符号名 [模块名]`，正是
`split_symbol_module()` 需要的。

### 坑 2：overlay 的 upperdir 必须在 tmpfs 上

最先我试 `/data/local/tmp`，overlay 一律 `EINVAL`。dmesg 里能看到真实原因：

```
overlay: case-insensitive capable filesystem on /data/local/tmp/ovl/upper not supported
```

`/data` 是开启了 casefold 的 f2fs，而内核未启用
`CONFIG_OVERLAY_FS_REDIRECT_DIR`，所以拒绝用作 upperdir。

正确做法是先挂 tmpfs 再在上面建 upperdir（脚本已处理）：

```shell
mount -t tmpfs tmpfs /mnt/ovlroot
mkdir -p /mnt/ovlroot/{up,wk,newroot}
mount -t overlay overlay \
  -o lowerdir=/,upperdir=/mnt/ovlroot/up,workdir=/mnt/ovlroot/wk /mnt/ovlroot/newroot
```

### 补充：.ko 必须真实拷贝，不能软链接

chroot 之后，指向 `/system_dlkm/...` 的绝对路径软链接解析不到。脚本用的是
`cp`，不是 `ln -s`。

## 排查

| 现象 | 原因 | 处理 |
|------|------|------|
| `No DWARF debug info found for kernel` | vmlinux 没进 chroot，或 build-id 不匹配 | 检查 `-d` 目录里的 `vmlinux-<rel>` 是否有效 |
| `Function 'X' not found in DWARF` | 模块 DWARF 未加载 | 确认模块已 `insmod` 且 `/lib/modules/<rel>/kernel/X.ko` 存在 |
| `-l 'kprobe:FUNC@*'` 无输出 | traceable 文件缺模块后缀 | 用 `gen_traceable.awk` 重新生成 |
| `overlay mount failed` | upperdir 在 f2fs 上 | 确认 upperdir 位于 tmpfs |
| `unknown option: -l` | 缺少 `--` 分隔 | 写成 `... -- -l '...'` |
| `chroot: exec /system/bin/sh: No such file` | 用了动态链接的程序当入口 | 只传静态链接的 bpftrace |
| attach 成功但计数为 0 | workload 没打到该行 | 换更热的函数，或加大压力负载 |

`Attached N probes` 只证明 attach 成功。必须观察计数增长才能声称命中。

## 限制

- 只在 arm64 Android（`6.12.69-android16-6-4k`）上验证过
- 需要 root 和 `CONFIG_OVERLAY_FS`
- `kptr_restrict=0` 是临时改动，重启后恢复
- 每次运行都要重建 overlay，482 个 `.ko` 的拷贝需要一点时间（脚本内 `cp`
  每轮实际耗时与模块总量有关）
- 这是绕过 libdwfl 路径限制的验证手段，不是 upstream 的正式支持方式
