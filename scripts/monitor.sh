#!/bin/sh
# 资源采集：每隔 INTERVAL 秒记录一次 CPU / 内存 / 网卡 / 温度的累计计数（差值由 scripts/analyze_mon.py 计算）。
# 在每台设备上运行（run_bench.sh 会自动启动和停止）：sh monitor.sh 输出.csv [间隔秒，默认 0.5]
# 列：ts_ms 时间戳(毫秒)；/proc/stat 第一行的 user nice system idle iowait irq softirq（单位 jiffies）；
#     mem_total_kb mem_avail_kb；rpc_rss_kb bench_rss_kb（ggml-rpc-server / llama-bench 的常驻内存）；
#     eth0 的 rx/tx 字节数和包数；temp_mc 温度(毫摄氏度)
OUT=$1; I=${2:-0.5}
IF=$(ip -o -4 addr show | awk '/10\.77\./{print $2; exit}'); [ -n "$IF" ] || IF=eth0
D=/sys/class/net/$IF/statistics
echo "ts_ms,user,nice,system,idle,iowait,irq,softirq,mem_total_kb,mem_avail_kb,rpc_rss_kb,bench_rss_kb,rx_bytes,tx_bytes,rx_packets,tx_packets,temp_mc" > "$OUT"
while :; do
  set -- $(head -1 /proc/stat)
  M=$(awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{print t","a}' /proc/meminfo)
  R=$(ps -o rss= -C ggml-rpc-server 2>/dev/null | awk '{s+=$1} END{print s+0}')
  B=$(ps -o rss= -C llama-bench,llama-batched-bench 2>/dev/null | awk '{s+=$1} END{print s+0}')
  echo "$(date +%s%3N),$2,$3,$4,$5,$6,$7,$8,$M,$R,$B,$(cat $D/rx_bytes),$(cat $D/tx_bytes),$(cat $D/rx_packets),$(cat $D/tx_packets),$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)" >> "$OUT"
  sleep "$I"
done
