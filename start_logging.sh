#!/bin/bash

LOG_DIR=~/logs/hyper-5gc
mkdir -p $LOG_DIR

# 停止旧的采集进程
kill $(ps aux | grep "docker logs" | grep -v grep | awk '{print $2}') 2>/dev/null
sleep 1

echo "=== 启动核心网日志采集 ==="

# 定义去颜色函数（复用）
strip_color="sed -r 's/\[[0-9;]*[mK]//g'"

# AMF (15个)
for r in r1 r2 r3; do for n in 1 2 3 4 5; do
  amf="amf-${r}-${n}"
  docker logs -f clab-hyper-5gc-hybrid-$amf 2>&1 | eval $strip_color >> $LOG_DIR/$amf.log &
  echo "  采集 $amf"
done; done

# SMF (20个)
for s in s1 s2 s3 s4; do for n in 1 2 3 4 5; do
  smf="smf-${s}-${n}"
  docker logs -f clab-hyper-5gc-hybrid-$smf 2>&1 | eval $strip_color >> $LOG_DIR/$smf.log &
  echo "  采集 $smf"
done; done

# UPF (36个)
for upf in upf-core-{1..6} upf-edge-{1..10} upf-local-{1..10} upf-regional-{21..30}; do
  docker logs -f clab-hyper-5gc-hybrid-$upf 2>&1 | eval $strip_color >> $LOG_DIR/$upf.log &
  echo "  采集 $upf"
done

# 核心控制面 NF (26个)
for nf in nrf nssf ausf-{1..5} bsf-{1..3} pcf-{1..6} udm-{1..5} udr-{1..5}; do
  docker logs -f clab-hyper-5gc-hybrid-$nf 2>&1 | eval $strip_color >> $LOG_DIR/$nf.log &
  echo "  采集 $nf"
done

echo ""
echo "日志采集进程数: $(ps aux | grep 'docker logs' | grep -v grep | wc -l)"
echo "日志目录: $LOG_DIR"
