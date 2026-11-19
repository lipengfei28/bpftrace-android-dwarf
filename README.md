# bpftrace-android-dwarf

在 Android 上使用 bpftrace 源码行 kprobe（`kprobe@FILE:LINE`）的实测文档与工具脚本。

主内核部分直接可用；内核模块（`.ko`）需要额外处理，本仓库提供了脚本。

## 内容

| 文件 | 说明 |
|------|------|
| [docs-android-dwarf-kprobe.md](docs-android-dwarf-kprobe.md) | 完整实测文档：失败根因、环境配置、验证记录、排查表 |
| [ko_dwarf_env.sh](ko_dwarf_env.sh) | 主脚本，用 overlayfs + chroot 让模块 DWARF 可加载 |
| [gen_traceable.awk](gen_traceable.awk) | 从 `/proc/kallsyms` 生成带模块后缀的函数清单 |
| [README-ko-dwarf.md](README-ko-dwarf.md) | 模块部分的使用说明，含排查表 |

## 快速开始

完整流程见文档。模块部分的四条命令：

```bash
# 1. 推文件
adb -s <serial> push ko_dwarf_env.sh   /data/local/tmp/
adb -s <serial> push gen_traceable.awk /data/local/tmp/
adb -s <serial> push <静态 bpftrace>    /data/local/tmp/bpftrace-fl
adb -s <serial> shell chmod 755 /data/local/tmp/bpftrace-fl

# 2. 生成函数清单
adb -s <serial> shell 'su 0 sh -c "
  awk -f /data/local/tmp/gen_traceable.awk /proc/kallsyms | sort -u \
    > /data/local/tmp/traceable.txt
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

注意第 4 步的 `--`：它之前是脚本参数，之后原样传给 bpftrace。

## 三个必备前提

| 前提 | 不做会怎样 |
|------|-----------|
| `kptr_restrict=0` | DWARF 完全加载不了，libdwfl 在算内核地址范围那一步就失败 |
| vmlinux 文件名是 `vmlinux-$(uname -r)` | `--debuginfo` 指定了目录也找不到 |
| 提供函数清单 | 连 `-l 'kprobe:FUNC'` 都没有输出 |

## 环境要求

- Android arm64，设备已 root
- 内核开启 `CONFIG_OVERLAY_FS`
- bpftrace 必须是**完全静态链接**的（chroot 需要）
- vmlinux 与运行内核 build-id 匹配，且带 DWARF

## 验证状态

只在 `6.12.69-android16-6-4k`（arm64）上实测过。已验证主内核和 `.ko` 模块的源码行列表、attach、命中；未验证 uprobe 和其他架构。

## 相关

- 上游项目：<https://github.com/bpftrace/bpftrace>
