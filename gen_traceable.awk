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
