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
