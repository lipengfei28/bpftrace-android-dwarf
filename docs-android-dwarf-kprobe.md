# bpftrace 在 Android 上使用 DWARF 源码行 kprobe

> 💡 本文所有结论都来自实测，环境和证据在文末「验证记录」一节。未实测的推断一律标 **未验证**。

## 先看结论

Android 上能让源码行 kprobe 工作的前提有三条，缺一条就走不通：

| 前提 | 不做会怎样 | 怎么做 |
|-|-|-|
| `kptr_restrict=0` | DWARF 根本加载不了，报 `No DWARF debug info found for kernel` | `echo 0 > /proc/sys/kernel/kptr_restrict`（重启恢复） |
| vmlinux 文件名必须是 `vmlinux-$(uname -r)` | `--debuginfo` 指定了目录也找不到 | 建软链接指向实际文件 |
| 提供函数清单 | 连 `-l 'kprobe:FUNC'` 都没输出 | 用 kallsyms 生成替代文件传给 `--traceable-functions` |

三条都满足后，源码行 kprobe 的查询、attach、命中全链路可用。

---

## 一、为什么 live 路径在 Android 上会失败

`dwfl_linux_kernel_report_kernel()` 的执行顺序决定了失败点：

```
dwfl_linux_kernel_report_kernel()
  -> intuit_kernel_bounds() 读 /proc/kallsyms 推内核地址范围
       kptr_restrict=2 时地址全为 0 -> start >= end -> 返回 -1
       返回值不是 ENOENT -> 直接失败，走不到找 vmlinux 那一步
       kptr_restrict=0 时地址正常 -> 继续往下
  -> 按 uname -r 拼出 vmlinux-<release>
  -> 在 --debuginfo 给的目录里查找（.debug 变体也试）
```

关键点：**`kptr_restrict=2` 时返回的是 `-1` 而不是 `ENOENT`**，所以 elfutils 不会退到「去找 vmlinux 文件」那一步，而是直接失败。这意味着把 vmlinux 放到正确路径也没用，必须先把地址放出来。

实测证据（`6.12.69-android16-6-4k`）：

```bash
# kptr_restrict=2 时，即使 root 也读不到地址
$ su 0 cat /proc/sys/kernel/kptr_restrict
2
$ su 0 head -1 /proc/kallsyms
0000000000000000 T _text

# 改成 0 之后
$ su 0 echo 0 > /proc/sys/kernel/kptr_restrict
$ su 0 head -1 /proc/kallsyms
ffffffdb10600000 T _text
```

---

## 二、`--debuginfo` 怎么用才生效

`--debuginfo DIR[:DIR]` 只决定**去哪些目录找**，不决定**找哪个文件**。

文件名由 elfutils 用 `uname -r` 拼死：

```text
/boot/vmlinux-<release>
/lib/modules/<release>/vmlinux
```

然后在 `--debuginfo` 给的每个目录下按这个文件名（以及 `.debug` 后缀变体）查找。所以：

| 场景 | 能否生效 |
|-|-|
| `DIR/vmlinux-$(uname -r)` → 软链到任意文件 | 能 |
| `DIR/vmlinux`（无 release 后缀） | 不能 |
| `DIR/vmlinux-某个build-id`（Android 常见命名） | 不能，除非建软链 |

> ⚠️ Android 设备上的 vmlinux 常带 build-id 后缀（如 `/data/vmlinux`、`vmlinux-ef41ceaf`），**直接用 `--debuginfo` 指过去是不生效的**，必须建一个符合 `vmlinux-$(uname -r)` 命名的软链接。

正确做法：

```bash
su 0 sh -c '
  mkdir -p /data/dbg
  ln -sf /data/vmlinux /data/dbg/vmlinux-$(uname -r)
  ls -la /data/dbg/
'
```

---

## 三、`available_filter_functions` 缺失的连锁反应

Android GKI 内核通常不开 `CONFIG_FUNCTION_TRACER`，于是 `/sys/kernel/tracing/available_filter_functions` 这个文件根本不存在：

```bash
$ su 0 zcat /proc/config.gz | grep FUNCTION_TRACER
# CONFIG_FUNCTION_TRACER is not set
$ su 0 ls /sys/kernel/tracing/available_filter_functions
ls: No such file or directory
```

bpftrace 读取失败时只打一条 warning，看起来无害：

```text
WARNING: Could not read functions from /sys/kernel/debug/tracing/available_filter_functions...
```

但后果比 warning 严重得多。`KernelInfoImpl::modules_` 这个函数集合**只**从该文件填充，文件缺失时集合为空，`is_traceable()` 对任何函数都返回 false。结果是 **`-l 'kprobe:FUNC'` 完全无输出** —— 不只是新功能，连基础的函数列表都不能用。

### 绕法：用 kallsyms 造一份等价文件

文件格式是每行一个函数名，跨模块时用 `funcname [module]`。内核主镜像的符号不需要后缀：

```bash
su 0 sh -c '
  awk "\$2 ~ /^[TtWw]\$/ {print \$3}" /proc/kallsyms | sort -u > /data/local/tmp/traceable.txt
  wc -l /data/local/tmp/traceable.txt
'
# 118480
```

然后显式传入：

```bash
--traceable-functions /data/local/tmp/traceable.txt
```

> ❌ 注意区分两种失败：**不传** `--traceable-functions` 且文件不存在 → 只是 warning，继续跑但函数清单为空；**传了**但文件打不开 → 直接报错退出。所以在 Android 上要么不传，要么确保文件存在。

---

## 四、完整可用的命令序列

以下命令在一台 arm64 Android 设备（`6.6.139-android15-8`）上实测跑通。

### 步骤 1：准备环境

```bash
su 0 sh -c '
  # 放开内核地址，重启后恢复
  echo 0 > /proc/sys/kernel/kptr_restrict

  # vmlinux 软链到 --debuginfo 期望的文件名
  mkdir -p /data/dbg
  ln -sf /data/vmlinux /data/dbg/vmlinux-$(uname -r)

  # 生成函数清单
  awk "\$2 ~ /^[TtWw]\$/ {print \$3}" /proc/kallsyms | sort -u > /data/local/tmp/traceable.txt
'
```

### 步骤 2：列出函数的所有源码行

```bash
su 0 env -u BPFTRACE_VMLINUX \
  /data/local/tmp/bpftrace \
  --debuginfo /data/dbg \
  --traceable-functions /data/local/tmp/traceable.txt \
  -l 'kprobe:vfs_read@*'
```

输出：

```text
kprobe@/proc/self/cwd/common/fs/read_write.c:486
kprobe@/proc/self/cwd/common/fs/read_write.c:489
kprobe@/proc/self/cwd/common/fs/read_write.c:490
kprobe@/proc/self/cwd/common/fs/read_write.c:491
kprobe@/proc/self/cwd/common/fs/read_write.c:492
kprobe@/proc/self/cwd/common/fs/read_write.c:551
...
```

本例共 17 行。加 `-v` 可以看到哪些行来自 inline：

```bash
su 0 env -u BPFTRACE_VMLINUX \
  /data/local/tmp/bpftrace \
  --debuginfo /data/dbg \
  --traceable-functions /data/local/tmp/traceable.txt \
  -lv 'kprobe:vfs_read@*'
```

输出（节选）：

```text
kprobe@/proc/self/cwd/common/fs/read_write.c:486 inline:new_sync_read
kprobe@/proc/self/cwd/common/fs/read_write.c:489 inline:new_sync_read
kprobe@/proc/self/cwd/common/fs/read_write.c:490 inline:new_sync_read
kprobe@/proc/self/cwd/common/fs/read_write.c:491 inline:new_sync_read
kprobe@/proc/self/cwd/common/fs/read_write.c:492 inline:new_sync_read
kprobe@/proc/self/cwd/common/fs/read_write.c:551
...
```

17 行里 5 行来自 `new_sync_read` inline。

### 步骤 3：attach 并采集

```bash
su 0 env -u BPFTRACE_VMLINUX \
  /data/local/tmp/bpftrace \
  --debuginfo /data/dbg \
  --traceable-functions /data/local/tmp/traceable.txt \
  -e 'kprobe@/proc/self/cwd/common/fs/read_write.c:551 { @hits = count(); }'
```

实测输出：

```text
Attached 2 probes
@hits: 15038
```

> ✅ `Attached N probes` 只证明 attach 成功。必须另外启动 workload 并观察计数增长，才能声称命中。上面的 15038 是在跑 3000 次 `cat /proc/self/status` 期间累计的。

## 五、build-id 校验与 vmlinux 匹配

PR #5448（已合入 master）新增了 build-id 校验：内核镜像的 GNU build ID 与运行内核不一致时拒绝使用，并打印两边 ID。

### 不匹配时的表现

```text
WARNING: Kernel image /data/dbg/vmlinux-6.12.69-android16-6-4k
  is not the running kernel:
  image build ID <image-build-id>,
  running kernel <running-build-id>.
WARNING: No DWARF debug info found for kernel, cannot list source code locations
```

匹配时则完全没有这条警告，直接输出结果。

### 匹配才是正解

实测中最容易误判的一点：**版本串相同不代表匹配**。

Android 内核用 `SOURCE_DATE_EPOCH` 做可复现构建，版本 banner 里的时间戳对所有构建都是 `Thu Jan 1 00:00:00 UTC 1970`。因此下面两份 vmlinux 的 banner 几乎逐字符一致，但 build-id 完全不同：

| 来源 | 版本串 | build-id |
|-|-|-|
| 设备运行内核（刷机前） | `6.12.69-android16-6-4k` | `<running-build-id>` |
| 手里的 vmlinux | `6.12.69-android16-6-4k` | `<image-build-id>` |

当时我据此判断「vmlinux 不匹配」，其实真正的原因是**设备还跑着旧内核，新 vmlinux 尚未刷入**。重刷设备后两边变成一致：

```text
运行内核 build-id   <image-build-id>
vmlinux build-id    <image-build-id>
```

校验通过，功能全部正常。

> ⚠️ 遇到 `is not the running kernel` 时，先确认设备**是否真的在跑你编译的那个内核**。用 fingerprint 和 `/proc/version` 的构建时间判断，不要只看版本号字符串。

### 判断 vmlinux 能否用的方法

当手头没有 build-id 完全匹配的 vmlinux 时，可以比对符号覆盖率来评估：

```bash
# 设备侧符号名
su 0 awk '$2=="T"||$2=="t"{print $3}' /proc/kallsyms | sort -u > /data/local/tmp/dev-syms.txt

# vmlinux 侧符号名
nm --defined-only vmlinux | awk '$2=="T"||$2=="t"{print $3}' | sort -u > vmlinux-syms.txt

# 覆盖率
comm -12 dev-syms.txt vmlinux-syms.txt | wc -l
```

实测数据（差一个构建版本的一对）：

```text
vmlinux 真符号   62615
与设备交集       61836     覆盖率 98.76%
缺失的 779 个    基本全是 __efistub_* / __kvm_nvhe_* 之类不进运行镜像的符号
```

覆盖率 98% 以上时，这份 vmlinux 大概率能用于源码行解析。

> ⚠️ 符号覆盖率只是经验判断，未经系统性验证。生产环境请使用 build-id 完全匹配的 vmlinux。临时去掉校验做验证可以，但不要把这个改动提交到上游。

判断标准：

| 覆盖率 | 可用性 |
|-|-|
| 接近 100% | 可以用于源码行解析 |
| 95% 以上，差异集中在 `__efistub_*` / `__kvm_nvhe_*` | 通常可用（这些符号不进运行镜像） |
| 明显偏低 | 不能用，布局差异会导致地址解析错误 |

> ⚠️ 这个判断是经验性的，未经系统性验证。生产环境仍应使用 build-id 完全匹配的 vmlinux。若确有需要，可以临时去掉校验做验证，但**不要把这个改动提交到上游**。

---

## 六、排查 DWARF 时最容易误判的一点

`readelf` 读不出 DWARF，**不等于 bpftrace 读不出**。

Android 内核的 DWARF 常用 zstd 压缩：

```bash
$ readelf --debug-dump=info vmlinux
readelf：警告： section '.debug_str' has unsupported compress type: 2
readelf：警告： section '.debug_info' has unsupported compress type: 2
```

`compress type: 2` 是 zstd（1 是 bzip2）。binutils 2.38 及更早版本不支持，于是 `readelf`、`addr2line` 全部读不出内容，看起来像「DWARF 是空的」。

而 elfutils 0.193 支持 zstd，bpftrace 完全正常。

**判定方法**：不要用 readelf 下结论，直接用 bpftrace 或 `eu-readelf` 验证。

---

## 七、常见错误对照表

| 现象 | 根因 | 解决 |
|-|-|-|
| `No DWARF debug info found for kernel` | 三种可能：`kptr_restrict` 未放开 / 找不到文件 / build-id 被拒 | 看前面是否有 `WARNING: Kernel image ... is not the running kernel`，有则是 build-id 问题；没有则检查 `kptr_restrict` 和软链 |
| `Could not read functions from ...available_filter_functions` | Android 内核没开 `CONFIG_FUNCTION_TRACER` | 用 kallsyms 生成替代文件传 `--traceable-functions` |
| `-l 'kprobe:FUNC'` 无任何输出 | 函数清单为空，`is_traceable()` 恒 false | 同上 |
| `-l 'kprobe:FUNC@*'` 无输出 | 同上；或函数名不在 DWARF 里 | 先确认 `nm vmlinux \| grep FUNC` 有该符号 |
| `Attached 1 probe` 但无输出 | workload 没触发该行 | 换热函数，或加大 workload |
| `Could not resolve symbol` | 用了局部符号（kallsyms 里是小写 `t`） | 换全局符号（大写 `T`） |

---

## 八、验证记录

所有数据均在一台 arm64 Android 设备上实测，build-id 完全匹配。

### 环境

| 项 | 值 |
|-|-|
| 设备 | arm64 Android（机型和序列号略去） |
| 系统版本 | Android 16，测试版 |
| 运行内核 | `6.12.69-android16-6-4k` |
| 运行内核 build-id | `<image-build-id>` |
| vmlinux | `/data/local/tmp/vmlinux` |
| vmlinux build-id | `<image-build-id>`（匹配） |
| 匹配状态 | build-id 一致 |
| bpftrace | `v0.27.0-aee91165`，aarch64 完全静态，含 build-id 校验 |

### 验证结果

第一步，列出函数所有源码行：

```bash
-l 'kprobe:vfs_read@*'
```

输出 17 行，build-id 校验放行。

第二步，inline 标注：

```bash
-lv 'kprobe:vfs_read@*'
```

17 行中有 5 行带 `inline:new_sync_read` 标注：

```text
kprobe@/proc/self/cwd/common/fs/read_write.c:486 inline:new_sync_read
kprobe@/proc/self/cwd/common/fs/read_write.c:489 inline:new_sync_read
kprobe@/proc/self/cwd/common/fs/read_write.c:490 inline:new_sync_read
kprobe@/proc/self/cwd/common/fs/read_write.c:491 inline:new_sync_read
kprobe@/proc/self/cwd/common/fs/read_write.c:492 inline:new_sync_read
```

第三步，非 inline 行 attach 与命中：

| 源码行 | 类型 | 结果 |
|-|-|-|
| `read_write.c:551` | 普通 | `Attached 2 probes`，命中 15038 |

第四步，inline 行 attach 与命中：

| 源码行 | inline 函数 | 命中次数 |
|-|-|-|
| `read_write.c:486` | `new_sync_read` | 1210 |
| `read_write.c:489` | `new_sync_read` | 1971 |
| `read_write.c:490` | `new_sync_read` | 1975 |
| `read_write.c:491` | `new_sync_read` | 1979 |
| `read_write.c:492` | `new_sync_read` | 1217 |

5 个 inline 行全部 attach 成功并命中。489/490/491 三次几乎相等（1971/1975/1979），说明是同一段连续代码路径；486 和 492 明显更低（约 1210），是分支才走到的位置。

workload 为 3000 次 `cat /proc/self/status`。

> ✅ `Attached N probes` 只证明 attach 成功，必须观察计数增长才能声称命中。上表的次数都是实际累加结果。

## 九、当前限制

### 已验证

- 主内核的源码行列表、attach、命中（build-id 完全匹配）
- inline 函数内的行：能列出、能标注、能 attach、能命中（5/5）
- build-id 校验在匹配时放行、不匹配时拒绝
- **内核模块（.ko）的源码行列表、attach、命中**（需要额外步骤，见第十节）

### 未验证

- uprobe 的同类行为
- arm64 之外的其他架构（只在 arm64 Android 和 x86_64 Ubuntu 测过）
- 模块 inline 函数的行标注

### 其他注意事项

- `kptr_restrict=0` 是设备安全设置的临时改动，重启后恢复，每轮需要重新设置
- 用符号覆盖率替代 build-id 匹配是经验做法，未经系统性验证
- `available_filter_functions` 缺失时，内核安全性过滤（blocklist）会被跳过

## 十、内核模块（.ko）的源码行 kprobe

主内核不需要额外处理，直接 `--debuginfo` 即可。模块则必须经过本节的处理，否则模块的 DWARF 根本加载不进来。

### 为什么模块不一样

libdwfl 查找模块 ELF 的路径写死在 elfutils：

```C#
/* libdwfl/linux-kernel-modules.c:797-800 */
/* Do "find /lib/modules/`uname -r` -name MODULE_NAME.ko".  */
asprintf (&modulesdir[0], MODULEDIRFMT, release);   /* "/lib/modules/%s" */
```

Android 上 `/lib` 不存在，`/` 是只读 erofs，无法创建：

```bash
$ ls -ld /lib
ls: /lib: No such file or directory
$ mount | grep ' / '
/dev/block/dm-9 on / type erofs (ro,seclabel,relatime,...)
$ su 0 mkdir /lib
mkdir: '/lib': Read-only file system
```

`--debuginfo` 补救不了。它只作用于主内核镜像和 debug 文件
（`try_kernel_name`，`linux-kernel-modules.c:99-118`），模块 ELF 的查找完全不经过这条路径。

### 解决办法：overlayfs + chroot

造一个可写的 `/`，把 `.ko` 放到 elfutils 期望的位置，再 chroot 进去运行 bpftrace。

```text
只读的 / (erofs)
      |
      | overlayfs（upperdir 在 tmpfs 上）
      v
 可写的 /mnt/ovlroot/newroot
      |
      +-- /lib/modules/<release>/kernel/*.ko   真实的 .ko 文件
      +-- /sys /proc /dev                      rbind 自真实系统
      |
      v
   chroot -> 完全静态链接的 bpftrace
```

整套逻辑已经封装成脚本，位置：

```text
<本仓库根目录>
    ko_dwarf_env.sh       主脚本
    gen_traceable.awk     生成函数清单
    README.md             完整说明
```

### 使用步骤

**步骤 1：推到设备**

```Bash
adb -s <serial> push ko_dwarf_env.sh   /data/local/tmp/
adb -s <serial> push gen_traceable.awk /data/local/tmp/
adb -s <serial> push <静态 bpftrace>    /data/local/tmp/bpftrace-fl
adb -s <serial> shell chmod 755 /data/local/tmp/bpftrace-fl
```

bpftrace 必须是**完全静态链接**的。chroot 之后 `/system/bin/sh` 无法执行，
只有静态二进制能当入口。

**步骤 2：生成函数清单**

```Bash
adb -s <serial> shell 'su 0 sh -c "
  awk -f /data/local/tmp/gen_traceable.awk /proc/kallsyms | sort -u \
    > /data/local/tmp/traceable.txt
  wc -l /data/local/tmp/traceable.txt
"'
```

预期输出 `194187 /data/local/tmp/traceable.txt` 这样的行。

**步骤 3：准备 vmlinux**

```Bash
adb -s <serial> shell 'su 0 sh -c "
  echo 0 > /proc/sys/kernel/kptr_restrict
  mkdir -p /data/local/tmp/dbg
  ln -sfn /data/local/tmp/vmlinux /data/local/tmp/dbg/vmlinux-$(uname -r)
"'
```

**步骤 4：运行**

```Bash
# 列出模块函数的全部源码行
adb -s <serial> shell 'su 0 unshare -m sh /data/local/tmp/ko_dwarf_env.sh \
  -- -l "kprobe:zs_malloc@*"'

# attach 到模块内的某个源码行
adb -s <serial> shell 'su 0 unshare -m sh /data/local/tmp/ko_dwarf_env.sh \
  -- -e "kprobe@/proc/self/cwd/common/mm/zsmalloc.c:332 { @hits = count(); }"'
```

> ⚠️ 脚本参数和 bpftrace 参数之间必须有 `--` 分隔符。没有它，bpftrace 的 `-l`
> 会被脚本自己的 getopts 吃掉，报 `unknown option: -l`。

### 实测结果

设备 `6.12.69-android16-6-4k`，vmlinux build-id `<image-build-id>` 与运行内核一致。

列出模块函数源码行：

```bash
$ su 0 unshare -m sh /data/local/tmp/ko_dwarf_env.sh -- -l 'kprobe:zs_malloc@*'
modules staged: 482
kprobe@/proc/self/cwd/common/mm/zsmalloc.c:332
kprobe@/proc/self/cwd/common/mm/zsmalloc.c:338
kprobe@/proc/self/cwd/common/mm/zsmalloc.c:450
...
```

attach 到模块源码行并命中：

```bash
$ ... -- -e 'kprobe@/proc/self/cwd/common/mm/zsmalloc.c:332 { @hits = count(); }'
Attached 2 probes
@hits: 753710
```

用模块限定的函数名做对照：

```bash
$ ... -- -e 'kprobe:zsmalloc:zs_malloc { @by_name = count(); }'
Attached 2 probes
@by_name: 92167
```

压力负载使用现成脚本：

```Bash
python3 app_launch_swipe_test.py \
  --serial <serial> --count 8 --settle-seconds 1.5 --swipe-direction up
```

### 两个必踩的坑

**坑 1：函数清单必须带模块后缀**

`/proc/kallsyms` 里模块符号长这样，模块名在第 4 列：

```text
ffffffe2fc8aee44 t zram_submit_bio	[zram]
```

如果写成 `$2 ~ /^[TtWw]$/ { print $3 }`，结果是 134554 行，但 `grep zram` 为 **0**。
所有模块符号都被当成 vmlinux 的，`is_traceable()` 查不到，
`-l 'kprobe:zs_malloc@*'` 静默返回空，没有任何报错。

正确写法见 `gen_traceable.awk`，输出格式是 `符号名 [模块名]`：

```text
$2 ~ /^[TtWw]$/ {
  if ($4 ~ /^\[/) {
    m = $4; gsub(/[\[\]]/, "", m); print $3 " [" m "]"
  } else print $3
}
```

这样生成 194187 行，zram 相关 378 条。

**坑 2：overlay 的 upperdir 必须在 tmpfs 上**

放 `/data/local/tmp` 会一律 `EINVAL`。dmesg 里有真实原因：

```text
overlay: case-insensitive capable filesystem on /data/local/tmp/ovl/upper not supported
```

`/data` 是开启 casefold 的 f2fs，而内核未启用
`CONFIG_OVERLAY_FS_REDIRECT_DIR`。脚本已经处理：先挂 tmpfs，再在 tmpfs 上建
upperdir。

**补充：`.ko` 必须真实拷贝，不能用软链接**

chroot 之后，指向 `/system_dlkm/...` 的绝对路径软链接解析不到。脚本用的是
`cp` 而不是 `ln -s`。

### 模块相关排查

| 现象 | 原因 | 处理 |
|-|-|-|
| `Function 'X' not found in DWARF` | 模块 DWARF 未加载 | 确认模块已 insmod，且 `/lib/modules/<rel>/kernel/X.ko` 存在 |
| `-l 'kprobe:FUNC@*'` 无输出 | 函数清单缺模块后缀 | 用 `gen_traceable.awk` 重新生成 |
| `overlay mount failed` | upperdir 在 f2fs 上 | 改到 tmpfs（脚本已处理） |
| `chroot: exec /system/bin/sh: No such file` | 用动态链接的程序当入口 | 只传静态链接的 bpftrace |
| attach 成功但计数为 0 | workload 没打到该行 | 换更热的函数，或加大压力负载 |

## 十一、脚本源码

上一节用到的两个脚本，完整内容如下，可直接复制保存。

### 附件

本节末尾附有三个文件，可直接下载：

- `ko_dwarf_env.sh` — 主脚本，overlayfs + chroot 环境准备并运行 bpftrace
- `gen_traceable.awk` — 从 `/proc/kallsyms` 生成带模块后缀的函数清单
- `android-ko-dwarf-README.md` — 完整说明文档，含排查表和已知限制

### ko_dwarf_env.sh

保存为 `ko_dwarf_env.sh`，推到设备任意可执行目录（示例用 `/data/local/tmp/`）。

```bash
#!/system/bin/sh
#
# 在 Android 上为内核模块（.ko）准备可用的 DWARF 环境，然后运行 bpftrace。
#
# 为什么需要这个脚本：
#   libdwfl 查找模块 ELF 的路径写死为 /lib/modules/<release>
#   （elfutils libdwfl/linux-kernel-modules.c:797-800）。Android 上 /lib 不存在，
#   且 / 是只读 erofs，无法创建。--debuginfo 也救不了，它只作用于主内核镜像
#   和 debug 文件，模块 ELF 的查找完全不经过它。
#
# 做法：用 overlayfs 造一个可写的 /，把模块 .ko 放到 elfutils 期望的位置，
#       再 chroot 进去运行 bpftrace。
#
# 用法（在设备上执行，需要 root 和独立 mount namespace）：
#   su 0 unshare -m sh ko_dwarf_env.sh -d /data/local/tmp/dbg \
#       -B /data/local/tmp/bpftrace-fl -T /data/local/tmp/traceable.txt \
#       -l 'kprobe:zs_malloc@*'
#
# 选项：
#   -d DIR   debuginfo 目录，需含 vmlinux-<uname -r>（默认 /data/local/tmp/dbg）
#   -B PATH  bpftrace 可执行文件，必须完全静态（默认 /data/local/tmp/bpftrace-fl）
#   -T PATH  traceable functions 文件（默认 /data/local/tmp/traceable.txt）
#   -h       显示本帮助
#
# 其余参数原样传给 bpftrace。

set -u

REL=$(uname -r)
OVL_ROOT=/mnt/ovlroot
NEWROOT=$OVL_ROOT/newroot

DBG_DIR=/data/local/tmp/dbg
BIN=/data/local/tmp/bpftrace-fl
TRACEABLE=/data/local/tmp/traceable.txt

while getopts "d:B:T:h" opt; do
  case $opt in
    d) DBG_DIR=$OPTARG ;;
    B) BIN=$OPTARG ;;
    T) TRACEABLE=$OPTARG ;;
    h) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: -$opt" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------

[ "$(id -u)" = "0" ] || die "must run as root (su 0 ...)"

# 必须已在独立 mount namespace 中，否则改动会泄漏到系统
if [ "$(readlink /proc/self/ns/mnt)" = "$(readlink /proc/1/ns/mnt)" ]; then
  die "not in a private mount namespace. Run as: su 0 unshare -m sh $0 ..."
fi

grep -qw overlay /proc/filesystems || die "kernel lacks overlayfs support"
[ -f "$BIN" ] || die "bpftrace binary not found: $BIN"
[ -f "$TRACEABLE" ] || die "traceable functions file not found: $TRACEABLE"

# 相对路径在 chroot 内会失效，统一转成绝对路径
case $DBG_DIR in /*) ;; *) DBG_DIR=/$(pwd)/$DBG_DIR ;; esac
case $BIN in /*) ;; *) BIN=/$(pwd)/$BIN ;; esac
case $TRACEABLE in /*) ;; *) TRACEABLE=/$(pwd)/$TRACEABLE ;; esac

[ -e "$DBG_DIR/vmlinux-$REL" ] \
  || die "$DBG_DIR/vmlinux-$REL not found. See README.md for providing vmlinux."

# ---------------------------------------------------------------------------
# 1. overlay：得到可写的 /
# ---------------------------------------------------------------------------

mkdir -p "$OVL_ROOT" || die "cannot create $OVL_ROOT"
mount -t tmpfs tmpfs "$OVL_ROOT" || die "cannot mount tmpfs on $OVL_ROOT"

# upperdir 必须位于 tmpfs。放 /data（f2fs 且开启 casefold）会失败：
#   overlay: case-insensitive capable filesystem on ... not supported
# 因为内核未启用 CONFIG_OVERLAY_FS_REDIRECT_DIR。
mkdir -p "$OVL_ROOT/up" "$OVL_ROOT/wk" "$NEWROOT" || die "cannot create overlay dirs"
mount -t overlay overlay \
  -o "lowerdir=/,upperdir=$OVL_ROOT/up,workdir=$OVL_ROOT/wk" \
  "$NEWROOT" || die "overlay mount failed"

# ---------------------------------------------------------------------------
# 2. 模块 .ko 放到 elfutils 期望的位置
# ---------------------------------------------------------------------------

MODROOT=$NEWROOT/lib/modules/$REL/kernel
mkdir -p "$MODROOT" || die "cannot create $MODROOT"

for d in /vendor_dlkm/lib/modules /odm_dlkm/lib/modules \
         /system_dlkm/lib/modules /vendor/lib/modules /system/lib/modules; do
  [ -d "$d" ] || continue
  for f in "$d"/*.ko; do
    [ -e "$f" ] || continue
    b=${f##*/}
    # 必须是真实拷贝。chroot 之后，指向原路径的绝对软链接解析不到。
    [ -e "$MODROOT/$b" ] || cp "$f" "$MODROOT/$b" 2>/dev/null
  done
done

MODCOUNT=$(ls "$MODROOT" 2>/dev/null | wc -l)
[ "$MODCOUNT" -gt 0 ] || die "no .ko files found under the dlkm directories"
echo "modules staged: $MODCOUNT"

# ---------------------------------------------------------------------------
# 3. 伪文件系统
# ---------------------------------------------------------------------------

# 用 --rbind：tracefs/debugfs 挂在 /sys 下，只有递归绑定才会一起带进来
mount --rbind /sys  "$NEWROOT/sys"  || die "rbind /sys failed"
mount --rbind /proc "$NEWROOT/proc" || die "rbind /proc failed"
mount --rbind /dev  "$NEWROOT/dev"  || die "rbind /dev failed"

# ---------------------------------------------------------------------------
# 4. 把 bpftrace 和输入文件搬进 chroot
# ---------------------------------------------------------------------------

mkdir -p "$NEWROOT/work" || die "cannot create work dir"

cp "$BIN"       "$NEWROOT/work/bpftrace" || die "cannot copy bpftrace"
cp "$TRACEABLE" "$NEWROOT/work/traceable.txt" || die "cannot copy traceable list"

# debuginfo 目录里需要的是 vmlinux-<release>。这里面通常是软链接，直接复制
# 会把链接本身搬进去，chroot 内解析不到；而完整复制一份 vmlinux 又要几百 MB。
# 所以只处理这一个名字：解析出真实文件，复制进 chroot，再重建链接。
mkdir -p "$NEWROOT$DBG_DIR" || die "cannot create $DBG_DIR"
REAL_VMLINUX=$(readlink -f "$DBG_DIR/vmlinux-$REL" 2>/dev/null \
  || echo "$DBG_DIR/vmlinux-$REL")
[ -f "$REAL_VMLINUX" ] || die "cannot resolve vmlinux-$REL"

cp "$REAL_VMLINUX" "$NEWROOT/work/vmlinux-real" || die "cannot copy vmlinux"
ln -sfn "/work/vmlinux-real" "$NEWROOT$DBG_DIR/vmlinux-$REL"

# ---------------------------------------------------------------------------
# 5. 在 chroot 内运行
# ---------------------------------------------------------------------------

# 不能用 chroot ... /system/bin/sh：Android 的 sh 依赖动态 linker，
# 在 chroot 内无法执行。bpftrace 是完全静态的，可以直接作为入口。
exec chroot "$NEWROOT" /work/bpftrace \
  --debuginfo "$DBG_DIR" \
  --traceable-functions /work/traceable.txt \
  "$@"
```

### gen_traceable.awk

保存为 `gen_traceable.awk`。

```awk
#!/system/bin/sh
#
# 从 /proc/kallsyms 生成 --traceable-functions 需要的文件。
#
# 为什么需要这个：Android GKI 内核通常不开 CONFIG_FUNCTION_TRACER，
# /sys/kernel/tracing/available_filter_functions 不存在。bpftrace 读不到它时
# 只打一条 warning，但内部函数集合为空，导致 -l 'kprobe:FUNC' 毫无输出。
#
# 关键点：模块符号必须带 [module] 后缀。kallsyms 里模块符号形如
#   ffffffe2fc8aee44 t zram_submit_bio	[zram]
# 模块名在第 4 列。只取 $3 会丢掉模块归属，全部被当成 vmlinux 的符号。
#
# 用法：
#   su 0 awk -f gen_traceable.awk /proc/kallsyms | sort -u > /data/local/tmp/traceable.txt
#
# 输出格式（每行一个）：
#   vmlinux_func
#   module_func [module_name]

$2 ~ /^[TtWw]$/ {
  if ($4 ~ /^\[/) {
    m = $4
    gsub(/[\[\]]/, "", m)
    print $3 " [" m "]"
  } else {
    print $3
  }
}
```

### 使用流程

```bash
# 1. 推文件到设备
adb -s <serial> push ko_dwarf_env.sh   /data/local/tmp/
adb -s <serial> push gen_traceable.awk /data/local/tmp/
adb -s <serial> push <静态 bpftrace>    /data/local/tmp/bpftrace-fl
adb -s <serial> shell chmod 755 /data/local/tmp/bpftrace-fl

# 2. 生成函数清单
adb -s <serial> shell 'su 0 sh -c "
  awk -f /data/local/tmp/gen_traceable.awk /proc/kallsyms | sort -u \
    > /data/local/tmp/traceable.txt
  wc -l /data/local/tmp/traceable.txt
"'

# 3. 准备 vmlinux
adb -s <serial> shell 'su 0 sh -c "
  echo 0 > /proc/sys/kernel/kptr_restrict
  mkdir -p /data/local/tmp/dbg
  ln -sfn /data/local/tmp/vmlinux /data/local/tmp/dbg/vmlinux-$(uname -r)
"'

# 4. 运行
adb -s <serial> shell 'su 0 unshare -m sh /data/local/tmp/ko_dwarf_env.sh \
  -- -l "kprobe:zs_malloc@*"'
```

注意第 4 步里的 `--` 分隔符：它之前是脚本参数，之后是 bpftrace 参数。

附件：[ko_dwarf_env.sh](ko_dwarf_env.sh)

附件：[gen_traceable.awk](gen_traceable.awk)

附件：[android-ko-dwarf-README.md](android-ko-dwarf-README.md)
---

## 十二、获取静态链接的 bpftrace

设备上运行的 bpftrace 必须满足三个条件，否则用不起来：

| 要求 | 原因 |
|------|------|
| 完全静态链接 | 设备上没有构建机的 glibc/LLVM 共享库 |
| 无 `PT_INTERP` | 不依赖 `/system/bin/linker64` |
| 无 `DT_NEEDED` | 不依赖任何 `.so` |

第十节的 `ko_dwarf_env.sh` 对这点要求更严格：它用 chroot 换根，动态链接的程序
在那里面无法执行（`/system/bin/sh` 就会失败），只有静态二进制能当入口。

### 构建脚本

完整的分步构建系统在本仓库：

```
static-build/aarch64-gnu/
```

它从干净的固定版本源码开始，用 `aarch64-linux-gnu-gcc/g++` 交叉编译全部依赖
（LLVM、bcc、libbpf、elfutils、blazesym、zlib 等），不把任何东西装到
`/usr` 或 `/usr/aarch64-linux-gnu`。

详细说明见 [static-build/aarch64-gnu/BUILD-zh.md](static-build/aarch64-gnu/BUILD-zh.md)。

### 最小流程

```bash
# 前置：交叉工具链
sudo apt install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu

cd static-build/aarch64-gnu
./scripts/build-all.sh
```

产物是 `prefix/bin/bpftrace`。依赖已编好时，只重新编译 bpftrace 可以走：

```bash
AARCH64_PREFIX="$PWD/prefix" \
BPFTRACE_SOURCE_DIR=/path/to/bpftrace \
BPFTRACE_BUILD_NAME=my-build \
  ./scripts/09-build-bpftrace.sh
```

### 产物验证

```bash
BIN=prefix/bin/bpftrace
file "$BIN"                                  # ARM aarch64, statically linked
readelf -d "$BIN"                            # no dynamic section
! readelf -l "$BIN" | grep -q PT_INTERP
! readelf -d "$BIN" | grep -Eq 'NEEDED|RPATH|RUNPATH'
"$BIN" --version
```

### 推到设备

```bash
adb -s <serial> push prefix/bin/bpftrace /data/local/tmp/bpftrace-fl
adb -s <serial> shell chmod 755 /data/local/tmp/bpftrace-fl

# 核对哈希，不要用设备上的旧文件
HOST_MD5=$(md5sum prefix/bin/bpftrace | awk '{print $1}')
DEV_MD5=$(adb -s <serial> shell md5sum /data/local/tmp/bpftrace-fl | tr -d '\r' | awk '{print $1}')
test "$HOST_MD5" = "$DEV_MD5" && echo OK
```
