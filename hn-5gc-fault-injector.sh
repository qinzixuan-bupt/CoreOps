#!/bin/bash

set -euo pipefail

# ─── 全局配置 ────────────────────────────────────────────────────────────────
LOG_DIR="${LOG_DIR:-./fault_logs}"
LABEL_FILE="${LOG_DIR}/fault_labels.json"
RUN_ID="run_$(date +%Y%m%d_%H%M%S)"
SCRIPT_PID=$$ 
NETWORK="${NETWORK:-clab-hyper-5gc-hybrid}"  
NRF_LOCK_FILE="/tmp/hn5gc_nrf_fault.lock"

# ─── 后台守护进程处理────────────────────────
if [[ "${1:-}" == "--daemon" ]]; then
    shift
    mkdir -p "$LOG_DIR"
    local_log_file="$LOG_DIR/injector_${RUN_ID}.log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 准备启动后台守护进程..." > "$local_log_file"
    nohup bash "$0" "$@" >> "$local_log_file" 2>&1 &
    echo "   后台运行已启动！"
    echo "   进程 PID: $!"
    echo "   日志文件: $local_log_file"
    echo "   查看日志: tail -f $local_log_file"
    exit 0
fi

# 随机调度参数（单位：秒）
SCHEDULER_MIN_INTERVAL=1500        # 两次故障最短间隔
SCHEDULER_MAX_INTERVAL=1800       # 两次故障最长间隔
SINGLE_FAULT_WEIGHT=99           # 单网元故障概率 %
DOUBLE_FAULT_WEIGHT=1           # 双网元故障概率 %

# 故障持续时间范围（秒）
DURATION_MIN=240
DURATION_MAX=1200

# ─── 网元列表 ────────────────────────────────────────────────────────────────
ALL_NFS=(
    amf-r1-1 amf-r1-2 amf-r1-3 amf-r1-4 amf-r1-5 amf-r2-1 amf-r2-2 amf-r2-3 amf-r2-4 amf-r2-5 amf-r3-1 amf-r3-2 amf-r3-3 amf-r3-4 amf-r3-5
    ausf-1 ausf-2 ausf-3 ausf-4 ausf-5 bsf-1 bsf-2 bsf-3 nrf nssf pcf-1 pcf-2 pcf-3 pcf-4 pcf-5 pcf-6
    smf-s1-1 smf-s1-2 smf-s1-3 smf-s1-4 smf-s1-5 smf-s2-1 smf-s2-2 smf-s2-3 smf-s2-4 smf-s2-5 smf-s3-1 smf-s3-2 smf-s3-3 smf-s3-4 smf-s3-5 smf-s4-1 smf-s4-2 smf-s4-3 smf-s4-4 smf-s4-5
    udm-1 udm-2 udm-3 udm-4 udm-5 udr-1 udr-2 udr-3 udr-4 udr-5
    upf-core-1 upf-core-2 upf-core-3 upf-core-4 upf-core-5 upf-core-6 upf-edge-1 upf-edge-2 upf-edge-3 upf-edge-4 upf-edge-5 upf-edge-6 upf-edge-7 upf-edge-8 upf-edge-9 upf-edge-10
    upf-local-1 upf-local-2 upf-local-3 upf-local-4 upf-local-5 upf-local-6 upf-local-7 upf-local-8 upf-local-9 upf-local-10 upf-regional-21 upf-regional-22 upf-regional-23
    upf-regional-24 upf-regional-25 upf-regional-26 upf-regional-27 upf-regional-28 upf-regional-29 upf-regional-30
)

# ─── 网元权重 ───
declare -A NF_WEIGHT
for nf in "${ALL_NFS[@]}"; do
    NF_WEIGHT[$nf]=1
done

# ─── 故障类型注册表 ───────────────────────────────────────────────────────────
declare -A FAULT_CATEGORY=(
    [link_disconnect]="link_fault"
    [link_delay]="link_fault"
    [link_loss]="link_fault"
    [link_bandwidth]="link_fault"
    [link_jitter]="link_fault"
    [nf_freeze]="nf_anomaly"
    [nf_crash]="nf_anomaly"
    [nf_blackhole]="nf_anomaly"
    [res_cpu]="resource_contention"
    [res_mem]="resource_contention"
    [res_io]="resource_contention"
)

FAULT_WEIGHTS=(
    "link_disconnect:15"
    "link_delay:8"
    "link_loss:15"
    "link_bandwidth:5"
    "link_jitter:3"
    "nf_freeze:15"
    "nf_crash:15"
    "nf_blackhole:12"
    "res_cpu:5"
    "res_mem:4"
    "res_io:0"
)

# ─── 辅助函数 ────────────────────────────────────────────────────────────────
add_prefix() {
    [[ "$1" == clab-hyper-5gc-hybrid-* ]] && echo "$1" || echo "clab-hyper-5gc-hybrid-$1"
}

log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
log_err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ $*" >&2; }

container_running() {
    docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true
}

rand_int() {
    # rand_int MIN MAX  →  [MIN, MAX]
    local min=$1 max=$2
    echo $(( min + RANDOM % (max - min + 1) ))
}

pick_weighted_fault() {
    local total=0
    for entry in "${FAULT_WEIGHTS[@]}"; do
        total=$(( total + ${entry##*:} ))
    done
    local r=$(( RANDOM % total ))
    local acc=0
    for entry in "${FAULT_WEIGHTS[@]}"; do
        local name=${entry%%:*}
        local w=${entry##*:}
        acc=$(( acc + w ))
        if (( r < acc )); then
            echo "$name"
            return
        fi
    done
}

pick_random_nf() {
    local exclude=${1:-"__none__"}
    local total=0
    local candidates=()
    local weights=()

    for nf in "${ALL_NFS[@]}"; do
        [[ "$nf" == "$exclude" ]] && continue
        local w=${NF_WEIGHT[$nf]:-10}   
        candidates+=("$nf")
        weights+=("$w")
        total=$(( total + w ))
    done

    if (( total == 0 )); then
        echo "${candidates[$(( RANDOM % ${#candidates[@]} ))]}"
        return
    fi

    local r=$(( RANDOM % total ))
    local acc=0
    for i in "${!candidates[@]}"; do
        acc=$(( acc + weights[i] ))
        if (( r < acc )); then
            echo "${candidates[i]}"
            return
        fi
    done
}

iso_now() { date +"%Y-%m-%dT%H:%M:%S"; }

# ─── JSON 标注函数 ────────────────────────────────────────────────────────────
init_label_file() {
    mkdir -p "$LOG_DIR"
    if [[ ! -f "$LABEL_FILE" ]]; then
        cat > "$LABEL_FILE" <<EOF
{
  "schema_version": "1.2",
  "description": "5G 核心网故障注入标注数据集",
  "run_history": []
}
EOF
    fi
}

append_label() {
    # append_label <json_object_string>
    local entry="$1"
    # 用 Python 做安全的 JSON append（bash 处理 JSON 太脆）
    python3 - "$LABEL_FILE" "$entry" <<'PYEOF'
import sys, json
fpath, entry_str = sys.argv[1], sys.argv[2]
with open(fpath, 'r') as f:
    data = json.load(f)
data['run_history'].append(json.loads(entry_str))
with open(fpath, 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PYEOF
}

build_label_json() {
    # 参数：fault_id targets fault_type category start_time end_time
    #       duration_sec params status mitigation_hint
    local fault_id="$1"
    local targets_json="$2"    # JSON array string
    local fault_type="$3"
    local category="$4"
    local start_time="$5"
    local end_time="$6"
    local duration_sec="$7"
    local params_json="$8"     # JSON object string
    local status="$9"
    local mitigation_hint="${10}"

    python3 - <<PYEOF
import json, sys
obj = {
    "fault_id": "$fault_id",
    "run_id": "$RUN_ID",
    "targets": $targets_json,
    "fault_type": "$fault_type",
    "fault_category": "$category",
    "start_time": "$start_time",
    "end_time": "$end_time",
    "duration_sec": $duration_sec,
    "params": $params_json,
    "status": "$status",
    "mitigation_hint": $mitigation_hint,
    "overlap_possible": True
}
print(json.dumps(obj, ensure_ascii=False))
PYEOF
}

# ─── 实验隔离：SBI 端口就绪探针 ──────────────────────────────────────
wait_for_sbi_ready() {
    local target=$1 port=${2:-8080}
    local timeout=15
    log "[ISOLATION-PROBE] 等待 $target SBI 端口 $port 就绪..."
    
    while true; do
        local http_code
        http_code=$(docker exec "$target" curl -s -o /dev/null -w "%{http_code}" -m 2 "http://127.0.0.1:${port}/" 2>/dev/null || echo "000")
        if [[ "$http_code" != "000" ]]; then
            log "[ISOLATION-PROBE] $target 端口 $port 就绪 (HTTP: $http_code)，应用层状态稳定"
            return 0
        fi
        sleep 1
        timeout=$((timeout-1))
        if (( timeout <= 0 )); then
            log_err "[ISOLATION-PROBE] $target 端口 $port 探针超时，环境可能未完全隔离！"
            return 1
        fi
    done
}

# ─── 故障注入函数 ─────────────────────────────────────────────────────────────
# 每个函数签名：inject_<type> TARGET DURATION [extra_params...]
# 每个函数负责：注入 → sleep → 恢复，并向调用方返回 params_json

## ── 大类 1：链路故障 ─────────────────────────────────────────────────────────

# ── 修改后的注入函数签名约定 ──────────────────────────────────────────
# inject_<type> TARGET DURATION RESULT_FILE
# 函数负责：将 params JSON 写入 RESULT_FILE
# 所有 log 调用已走 stderr，stdout 不再使用

inject_link_disconnect() {
    local target=$1 dur=$2 result_file=$3
    log "[FAULT][link_disconnect] $target 断联 ${dur}s"
    docker network disconnect "$NETWORK" "$target" 2>/dev/null || true
    sleep "$dur"
    docker network connect "$NETWORK" "$target" 2>/dev/null || true
    log "[RESTORE][link_disconnect] $target 已重连"
    # 写入结果文件，而非 echo 到 stdout
    echo '{"action":"docker_network_disconnect"}' > "$result_file"
}

inject_link_delay() {
    local target=$1 dur=$2 result_file=$3
    local delay_ms
    delay_ms=$(rand_int 100 800)
    local pid
    pid=$(docker inspect -f '{{.State.Pid}}' "$target" 2>/dev/null)
    log "[FAULT][link_delay] $target 注入 ${delay_ms}ms 时延，持续 ${dur}s"
    nsenter -t "$pid" -n -- bash -c "
        tc qdisc del dev eth0 root 2>/dev/null || true
        tc qdisc add dev eth0 root netem delay ${delay_ms}ms
    "
    sleep "$dur"
    nsenter -t "$pid" -n -- tc qdisc del dev eth0 root 2>/dev/null || true
    log "[RESTORE][link_delay] $target 时延规则已清除"
    echo "{\"delay_ms\":$delay_ms,\"interface\":\"eth0\"}" > "$result_file"
}

inject_link_loss() {
    local target=$1 dur=$2 result_file=$3
    local loss_pct
    loss_pct=$(rand_int 5 40)
    local pid
    pid=$(docker inspect -f '{{.State.Pid}}' "$target" 2>/dev/null)
    log "[FAULT][link_loss] $target 注入 ${loss_pct}% 丢包，持续 ${dur}s"
    nsenter -t "$pid" -n -- bash -c "
        tc qdisc del dev eth0 root 2>/dev/null || true
        tc qdisc add dev eth0 root netem loss ${loss_pct}%
    "
    sleep "$dur"
    nsenter -t "$pid" -n -- tc qdisc del dev eth0 root 2>/dev/null || true
    log "[RESTORE][link_loss] $target 丢包规则已清除"
    echo "{\"loss_percent\":$loss_pct,\"interface\":\"eth0\"}" > "$result_file"
}

inject_link_bandwidth() {
    local target=$1 dur=$2 result_file=$3
    local bw_kbps
    bw_kbps=$(rand_int 128 2048)
    local pid
    pid=$(docker inspect -f '{{.State.Pid}}' "$target" 2>/dev/null)
    log "[FAULT][link_bandwidth] $target 限速 ${bw_kbps}kbps，持续 ${dur}s"
    nsenter -t "$pid" -n -- bash -c "
        tc qdisc del dev eth0 root 2>/dev/null || true
        tc qdisc add dev eth0 root tbf rate ${bw_kbps}kbit burst 32kbit latency 400ms
    "
    sleep "$dur"
    nsenter -t "$pid" -n -- tc qdisc del dev eth0 root 2>/dev/null || true
    log "[RESTORE][link_bandwidth] $target 限速规则已清除"
    echo "{\"bandwidth_kbps\":$bw_kbps,\"interface\":\"eth0\"}" > "$result_file"
}

inject_link_jitter() {
    local target=$1 dur=$2 result_file=$3
    local base_ms jitter_ms
    base_ms=$(rand_int 30 100)
    jitter_ms=$(rand_int 10 50)
    local pid
    pid=$(docker inspect -f '{{.State.Pid}}' "$target" 2>/dev/null)
    log "[FAULT][link_jitter] $target 注入 ${base_ms}±${jitter_ms}ms 抖动，持续 ${dur}s"
    nsenter -t "$pid" -n -- bash -c "
        tc qdisc del dev eth0 root 2>/dev/null || true
        tc qdisc add dev eth0 root netem delay ${base_ms}ms ${jitter_ms}ms distribution normal
    "
    sleep "$dur"
    nsenter -t "$pid" -n -- tc qdisc del dev eth0 root 2>/dev/null || true
    log "[RESTORE][link_jitter] $target 抖动规则已清除"
    echo "{\"base_delay_ms\":$base_ms,\"jitter_ms\":$jitter_ms,\"interface\":\"eth0\"}" \
        > "$result_file"
}

inject_nf_freeze() {
    local target=$1 dur=$2 result_file=$3
    log "[FAULT][nf_freeze] $target 进程冻结 ${dur}s"
    docker kill --signal=SIGSTOP "$target" 2>/dev/null || true
    sleep "$dur"
    docker kill --signal=SIGCONT "$target" 2>/dev/null || true
    log "[RESTORE][nf_freeze] $target 进程已恢复"
    echo '{"signal":"SIGSTOP","restore_signal":"SIGCONT"}' > "$result_file"
}

inject_nf_crash() {
    local target=$1 dur=$2 result_file=$3
    local start_epoch=$(date +%s)
    
    log "[FAULT][nf_crash] $target 进程崩溃"
    docker kill --signal=SIGKILL "$target" 2>/dev/null || true
    
    # 等待容器自动重启
    local waited=0
    while ! container_running "$target" && (( waited < 30 )); do
        sleep 2; waited=$(( waited + 2 ))
    done
    if ! container_running "$target"; then
        log_err "容器 $target 未能自动重启，尝试拉起"
        docker start "$target" 2>/dev/null || true
        sleep 5
    fi

    # ── 时序修复：计算重启消耗的时间，补齐剩余的故障持续时间 ──
    local elapsed=$(( $(date +%s) - start_epoch ))
    local remain=$(( dur - elapsed ))
    if (( remain > 0 )); then
        sleep "$remain"
    fi

    log "[RESTORE][nf_crash] $target 已恢复 (总耗时: $(( $(date +%s) - start_epoch ))s)"
    echo '{"signal":"SIGKILL","restart_policy":"on-failure"}' > "$result_file"
}

inject_nf_blackhole() {
    local target=$1 dur=$2 result_file=$3
    log "[FAULT][nf_blackhole] $target 入站流量黑洞"
    docker exec "$target" bash -c "
        iptables -F INPUT 2>/dev/null || \
            (apk add --no-cache iptables -q && iptables -F INPUT 2>/dev/null) || true
        iptables -I INPUT 1 -j DROP 2>/dev/null || true
    " 2>/dev/null || true
    sleep "$dur"
    docker exec "$target" bash -c \
        "iptables -D INPUT 1 2>/dev/null || true" 2>/dev/null || true
    sleep 3
    log "[RESTORE][nf_blackhole] $target 流量规则已清除"
    echo '{"method":"iptables_drop","direction":"inbound"}' > "$result_file"
}

inject_res_cpu() {
    local target=$1 dur=$2 result_file=$3
    local cpu_workers
    cpu_workers=$(rand_int 2 4)
    local safe_cpu_limit="2.0"
    docker update --cpus="$safe_cpu_limit" "$target" 2>/dev/null || true
    log "[FAULT][res_cpu] $target CPU 压力（${cpu_workers} workers，硬限 ${safe_cpu_limit} 核）${dur}s"
    docker exec -d "$target" bash -c "
        which stress-ng 2>/dev/null || \
            (apt-get install -y -q stress-ng 2>/dev/null || \
             apk add --no-cache stress-ng 2>/dev/null) || true
        stress-ng --cpu $cpu_workers --timeout ${dur}s --quiet &
    " 2>/dev/null || true
    sleep "$dur"
    docker exec "$target" bash -c \
        "pkill -f stress-ng 2>/dev/null || true" 2>/dev/null || true
    docker update --cpus=0 "$target" 2>/dev/null || true
    log "[RESTORE][res_cpu] $target CPU 压力已清除"
    echo "{\"cpu_workers\":$cpu_workers,\"safe_limit\":\"$safe_cpu_limit\",\"tool\":\"stress-ng\"}" \
        > "$result_file"
}

inject_res_mem() {
    local target=$1 dur=$2 result_file=$3
    local safe_mem_limit="512m"
    docker update --memory="$safe_mem_limit" \
                  --memory-swap="$safe_mem_limit" "$target" 2>/dev/null || true
    local mem_mb
    mem_mb=$(rand_int 128 450)
    log "[FAULT][res_mem] $target 内存压力 ${mem_mb}MB（硬限 ${safe_mem_limit}），持续 ${dur}s"
    docker exec -d "$target" bash -c "
        which stress-ng 2>/dev/null || \
            (apt-get install -y -q stress-ng 2>/dev/null || \
             apk add --no-cache stress-ng 2>/dev/null) || true
        stress-ng --vm 1 --vm-bytes ${mem_mb}M --timeout ${dur}s --quiet &
    " 2>/dev/null || true
    sleep "$dur"
    docker exec "$target" bash -c \
        "pkill -f stress-ng 2>/dev/null || true" 2>/dev/null || true
    docker update --memory=0 --memory-swap=0 "$target" 2>/dev/null || true
    log "[RESTORE][res_mem] $target 内存压力已清除"
    echo "{\"mem_mb\":$mem_mb,\"safe_limit\":\"$safe_mem_limit\",\"tool\":\"stress-ng\"}" \
        > "$result_file"
}

inject_res_io() {
    local target=$1 dur=$2
    
    # ── 新增：I/O 动态安全兜底 ──
    # 限制该容器最大写入速度为 10MB/s，读取 20MB/s，防止榨干公共磁盘
    docker update --device-write-bps="/dev/sda:10mb" --device-read-bps="/dev/sda:20mb" "$target" 2>/dev/null || \
    docker update --device-write-bps="/dev/vda:10mb" --device-read-bps="/dev/vda:20mb" "$target" 2>/dev/null || true
    # 注意：/dev/sda 和 /dev/vda 需要根据你服务器的实际磁盘名调整 (用 lsblk 查看)

    log "[FAULT][res_io] $target 磁盘 I/O 压力（已限速保护宿主机），持续 ${dur}s"
    docker exec -d "$target" bash -c "..." # 原有逻辑
    sleep "$dur"
    
    # 清理...
    
    # ── 新增：解除 I/O 限制恢复原状 ──
    docker update --device-write-bps="" --device-read-bps="" "$target" 2>/dev/null || true
    
    log "[RESTORE][res_io] $target I/O 压力已清除"
    echo '{"hdd_workers":2,"hdd_bytes":"256M","tool":"stress-ng","io_limited":true}'
}

# ─── 基站联动重启函数 ──────────────────────────────────────────────
restart_gnbs_if_amf() {
    local short_target=$1
    # 检查重启的网元是不是 AMF (匹配 amf-a1, amf-a2 等)
    if [[ "$short_target" == amf-* ]]; then
        log "[STATE-SYNC] 检测到 AMF [$short_target] 发生重启，联动拉起 gNodeB 集群..."
        # 使用后台运行，避免阻塞故障注入器的后续计时
        # 将 gNB 启动脚本的输出重定向到黑洞，防止干扰注入器日志
        bash ~/start_gnbs.sh >/dev/null 2>&1 &
        log "[STATE-SYNC] gNodeB 重启脚本已在后台触发"
    fi
}

# ─── 故障分发器 ───────────────────────────────────────────────────────────────
run_fault() {
    local short_target=$1 fault_type=$2 dur=$3
    local target
    target=$(add_prefix "$short_target")

    # ── 健康检查 ──────────────────────────────────────────────────────
    if ! container_running "$target"; then
        log_err "容器 $target 未运行，尝试修复并启动"
        docker start "$target" 2>/dev/null || true
        sleep 3
        if ! container_running "$target"; then
            log_err "无法恢复 $target，跳过注入"
            if [[ "$short_target" == "nrf" ]]; then
                rm -f "$NRF_LOCK_FILE"
                log "🔓 [FAIL-SAFE] NRF 互斥锁已释放"
            fi
            return 1
        fi
    fi

    local fault_id
    fault_id="fault_$(date +%Y%m%d%H%M%S)_${RANDOM}"
    local category="${FAULT_CATEGORY[$fault_type]}"
    local start_time
    start_time=$(iso_now)
    local status="success"

    # ── 核心修复：用临时文件接收 params_json ──────────────────────────
    local result_file
    result_file=$(mktemp /tmp/fault_result_XXXXXX.json)
    # 写入合法的默认值，防止注入函数意外退出时文件为空
    echo '{}' > "$result_file"

    local inject_fn="inject_${fault_type//-/_}"

    # 调用注入函数，传入 result_file；stdout/stderr 均定向到日志
    if ! "$inject_fn" "$target" "$dur" "$result_file" 2>&1; then
        status="failed"
        echo '{"error":"injection_failed"}' > "$result_file"
        log_err "注入函数 $inject_fn 执行失败"
    fi

    # ── 读取并校验 JSON ───────────────────────────────────────────────
    local params_json
    params_json=$(cat "$result_file")
    rm -f "$result_file"   # 立即清理临时文件

    # 用 Python 校验是否为合法 JSON，非法时用安全默认值替换
    if ! python3 -c "import json,sys; json.loads(sys.argv[1])" \
            "$params_json" 2>/dev/null; then
        log_err "result_file 内容不是合法 JSON：[$params_json]，已替换为默认值"
        params_json='{"error":"invalid_json_from_injector"}'
        status="failed"
    fi

    local end_time
    end_time=$(iso_now)

    # ── 生成 mitigation_hint ──────────────────────────────────────────
    local mitigation_hint
    mitigation_hint=$(python3 - "$fault_type" "$short_target" "$category" <<'PYEOF'
import sys, json
ft, tgt, cat = sys.argv[1], sys.argv[2], sys.argv[3]
hints = {
    "link_fault":           {"action": "check_link_and_reroute",  "check": "interface_stats"},
    "nf_anomaly":           {"action": "restart_or_failover",     "check": "process_health"},
    "resource_contention":  {"action": "scale_or_throttle",       "check": "cgroup_usage"},
}
obj = hints.get(cat, {"action": "investigate", "check": "logs"})
obj["target"] = tgt
print(json.dumps(obj))
PYEOF
)

    # ── 追加标注 ──────────────────────────────────────────────────────
    local targets_json
    targets_json=$(python3 -c \
        "import json; print(json.dumps(['$short_target']))")
    local label
    label=$(build_label_json \
        "$fault_id" "$targets_json" "$fault_type" "$category" \
        "$start_time" "$end_time" "$dur" \
        "$params_json" "$status" "$mitigation_hint")

    append_label "$label"
    log "[LABEL] 已记录 fault_id=$fault_id type=$fault_type" \
        "target=$short_target dur=${dur}s status=$status"

    # ────────────── 实验隔离保障开始 ──────────────
    log "[ISOLATION] $short_target 底层故障已撤销，开始应用层状态重置..."
    
    # 核心改进：针对进程级异常，引入“容器级重启”作为内存状态清洗剂
    if [[ "$fault_type" == "nf_freeze" ]] || [[ "$fault_type" == "nf_crash" ]]; then
        log "[ISOLATION] 检测到进程级异常 ($fault_type)，内存状态极大概率脏污，执行强制容器重启以清空用户态..."
        docker restart "$target" >/dev/null 2>&1 || true
        # 重启后必须等待容器主进程就绪，不能盲目继续
        wait_for_sbi_ready "$target" 8080 || true
    fi

    # 根据网元类型执行特定的 5G 协议栈状态重连/对齐
    case "$short_target" in
        amf-*)
            # AMF 内存清空后，必须强制 gNB 重连，否则 NGAP 链路处于僵死状态
            log "[ISOLATION] 检测到 AMF 状态重置，触发 gNodeB 强制重连以刷新 NGAP 状态..."
            bash ~/start_gnbs.sh >/dev/null 2>&1 || true
            ;;
        smf-*|upf-*)
            # 🚨 核心改进：不再用魔法数字 sleep 5，而是根据 5G 协议超时设计等待时间
            # SMF/UPF 的 PFCP 会话通常有保活机制，强制重启容器后，对端会话丢失
            # 等待一个 PFCP 心跳周期（通常 5-10s）让对端感知到断开并主动清理僵尸隧道
            log "[ISOLATION] SMF/UPF 状态已强制重置，等待对端 PFCP/GTP 僵尸会话超时注销 (10s)..."
            sleep 10
            ;;
        nrf|udr|udm|ausf|pcf)
            # UDR/UDM 等数据网元，如果是内存数据库（如free5GC默认的SQLite），重启已经清空缓存
            # 如果是连接外部 DB，无需处理，DB 事务本身具有隔离性。这里只等 SBI 就绪即可。
            log "[ISOLATION] 数据/注册类网元已重置，等待 SBI 就绪..."
            ;;
        *)
            sleep 2
            ;;
    esac

    # 最终防线：确保 SBI 端口完全就绪，防止脏状态带入下一轮实验
    wait_for_sbi_ready "$target" 8080 || true
    log "[ISOLATION] ✅ $short_target 实验环境隔离重置完成"
    # ────────────── 实验隔离保障结束 ──────────────

    if [[ "$short_target" == "nrf" ]]; then
        rm -f "$NRF_LOCK_FILE"
        log "🔓 NRF 互斥锁已释放"
    fi
}

run_dual_fault() {
    local nf1=$1 nf2=$2 type1=$3 type2=$4 dur1=$5 dur2=$6

    log "=== 双网元故障注入（严格串行隔离模式）：[$nf1/$type1] + [$nf2/$type2] ==="

    # 🚨 核心修复：彻底去掉 &，第一个网元【注入->持续->完全隔离重置】后，再启动第二个
    run_fault "$nf1" "$type1" "$dur1" || true
    
    # 可选：在两个网元之间加一个极短的喘息时间，模拟更真实的间歇故障
    sleep $(rand_int 2 5)
    
    run_fault "$nf2" "$type2" "$dur2" || true

    log "=== 双网元串行故障注入及隔离重置完成 ==="
}

# ─── 随机调度器 ───────────────────────────────────────────────────────────────
scheduler_loop() {
    local total_runtime_sec=${1:-$((7 * 24 * 3600))}  # 默认 7 天
    local elapsed=0

    log "========================================"
    log "  故障注入调度器启动（严格串行隔离模式）"
    log "  计划运行: ${total_runtime_sec}s (≈$(( total_runtime_sec/3600 ))h)"
    log "  标注文件: $LABEL_FILE"
    log "  PID: $SCRIPT_PID"
    log "========================================"

    while (( elapsed < total_runtime_sec )); do
        local wait_sec
        wait_sec=$(rand_int "$SCHEDULER_MIN_INTERVAL" "$SCHEDULER_MAX_INTERVAL")
        log "--- 下次注入等待 ${wait_sec}s ---"
        sleep "$wait_sec"
        elapsed=$(( elapsed + wait_sec ))
        (( elapsed >= total_runtime_sec )) && break

        if [[ -f "$NRF_LOCK_FILE" ]]; then
            log "⚠️  检测到 NRF 正处于故障期，为保护其他网元启动依赖，本轮调度跳过"
            continue
        fi

        local dice=$(( RANDOM % 100 ))
        local dur1
        dur1=$(rand_int "$DURATION_MIN" "$DURATION_MAX")

        if (( dice < SINGLE_FAULT_WEIGHT )); then
            local nf1
            nf1=$(pick_random_nf)
            local ft1
            ft1=$(pick_weighted_fault)
            
            if [[ "$nf1" == "nrf" ]]; then
                touch "$NRF_LOCK_FILE"
                log "🔒 NRF 互斥锁已加锁"
            fi
            
            log ">>> 单网元故障：$nf1 / $ft1 / ${dur1}s"
            # 🚨 核心修改：去掉 &，阻塞等待故障全生命周期结束
            run_fault "$nf1" "$ft1" "$dur1" || true
        else
            local nf1 nf2 ft1 ft2 dur2
            nf1=$(pick_random_nf)
            nf2=$(pick_random_nf "$nf1")
            ft1=$(pick_weighted_fault)
            ft2=$(pick_weighted_fault)
            dur2=$(rand_int "$DURATION_MIN" "$DURATION_MAX")
            
            if [[ "$nf1" == "nrf" ]] || [[ "$nf2" == "nrf" ]]; then
                local nrf_target="$nf1"
                local nrf_ft="$ft1"
                [[ "$nf2" == "nrf" ]] && { nrf_target="$nf2"; nrf_ft="$ft2"; }
                
                touch "$NRF_LOCK_FILE"
                log "🔒 NRF 互斥锁已加锁（双网元降级为单网元 NRF 注入）"
                log ">>> 降级单网元故障：$nrf_target / $nrf_ft / ${dur1}s"
                # 🚨 核心修改：去掉 & 和无意义的 elapsed 计算
                run_fault "$nrf_target" "$nrf_ft" "$dur1" || true
                continue
            fi

            log ">>> 双网元故障：[$nf1/$ft1/${dur1}s] + [$nf2/$ft2/${dur2}s]"
            # 🚨 核心修改：去掉 &，等待双网元并发故障及其后续恢复全部完成
            run_dual_fault "$nf1" "$nf2" "$ft1" "$ft2" "$dur1" "$dur2" || true
        fi
    done

    log "========================================"
    log "  调度器结束，总计 ${elapsed}s"
    log "  完整标注：$LABEL_FILE"
    log "========================================"
}

# ─── 信号处理 ─────────────────────────────────────────────────────────────────
cleanup_all() {
    log "=== 收到中断信号，执行全量防御性清理与状态恢复 ==="

    for nf in "${ALL_NFS[@]}"; do
        local t
        t=$(add_prefix "$nf")
        
        if docker inspect "$t" >/dev/null 2>&1; then
            
            # ── 第 1 层：Docker 引擎级状态强制回滚 ──
            docker update --restart="on-failure" "$t" 2>/dev/null || true
            docker update --memory=0 --memory-swap=0 "$t" 2>/dev/null || true
            docker update --cpus=0 "$t" 2>/dev/null || true

            # ── 第 2 层：容器内部环境清理 ──
            local pid
            pid=$(docker inspect -f '{{.State.Pid}}' "$t" 2>/dev/null || echo "0")
            
            if [[ "$pid" != "0" ]]; then
                nsenter -t "$pid" -n -- tc qdisc del dev eth0 root 2>/dev/null || true
                
                docker exec "$t" bash -c "
                    iptables -D INPUT 1 2>/dev/null || true
                    nft delete table ip fault_inject 2>/dev/null || true
                    pkill -f stress-ng 2>/dev/null || true
                " 2>/dev/null || true
                
                docker kill --signal=SIGCONT "$t" 2>/dev/null || true
            fi

            # ── 第 3 层：网络平面与生命周期恢复 ──
            docker network connect "$NETWORK" "$t" 2>/dev/null || true

            if ! container_running "$t"; then
                log "[CLEANUP] 容器 $t 处于停止状态，尝试拉起..."
                docker start "$t" 2>/dev/null || true
                
                # 如果拉起的是 AMF，顺手把 gNB 也拉起
                restart_gnbs_if_amf "$nf"
            else
                log "[CLEANUP] 容器 $t 已运行，跳过修复"
            fi
        fi
    done
    log "[CLEANUP] 核心网网元已全部拉起，等待内部集群状态稳定 (10秒)..."
    sleep 10
    log "=== 全量清理完成，所有网元状态已重置至基准线 ==="
    exit 0
}
trap cleanup_all SIGINT SIGTERM

# ─── 手动注入模式 ─────────────────────────────────────────────────────────────
manual_inject() {
    local mode=$1 target=$2 dur=${3:-30}
    shift 3 || true

    case "$mode" in
        disconnect)   run_fault "$target" "link_disconnect" "$dur" ;;
        delay)        run_fault "$target" "link_delay"      "$dur" ;;
        loss)         run_fault "$target" "link_loss"       "$dur" ;;
        bandwidth)    run_fault "$target" "link_bandwidth"  "$dur" ;;
        jitter)       run_fault "$target" "link_jitter"     "$dur" ;;
        freeze)       run_fault "$target" "nf_freeze"       "$dur" ;;
        crash)        run_fault "$target" "nf_crash"        "$dur" ;;
        blackhole)    run_fault "$target" "nf_blackhole"    "$dur" ;;
        cpu)          run_fault "$target" "res_cpu"         "$dur" ;;
        mem)          run_fault "$target" "res_mem"         "$dur" ;;
        io)           run_fault "$target" "res_io"          "$dur" ;;
        *)
            echo "未知故障类型: $mode"; show_help; exit 1 ;;
    esac
}

# ─── 帮助信息 ─────────────────────────────────────────────────────────────────
show_help() {
cat <<'HELP'
用法：
  自动随机调度（推荐）：
    ./hn-5gc-fault-injector.sh auto [总运行秒数]
    ./hn-5gc-fault-injector.sh auto $((7*24*3600))   # 运行 7 天

  手动单次注入：
    ./hn-5gc-fault-injector.sh <故障类型> <网元短名> [持续秒数]

故障类型：
  链路故障（link_fault）：
    disconnect  —  网络断联
    delay       —  高时延
    loss        —  随机丢包
    bandwidth   —  带宽限速
    jitter      —  链路抖动

  网元异常（nf_anomaly）：
    freeze      —  进程假死（SIGSTOP）
    crash       —  进程崩溃（SIGKILL+重启）
    blackhole   —  入站黑洞（iptables DROP）

  资源竞争（resource_contention）：
    cpu         —  CPU 压力（stress-ng，容器内）
    mem         —  内存压力（stress-ng，容器内）
    io          —  磁盘 I/O 压力（stress-ng，容器内）

支持的网元：
  nrf nssf nef udr udm ausf pcf prometheus
  amf-a1/a2/b1/b2/c1   smf-e1/e2/u1/u2/m1   upf-e1/e2/u1/u2/m1

示例：
  ./hn-5gc-fault-injector.sh auto
  ./hn-5gc-fault-injector.sh disconnect amf-a1 30
  ./hn-5gc-fault-injector.sh delay upf-e1 60
  ./hn-5gc-fault-injector.sh cpu smf-m1 45

输出：
  标注文件：./fault_logs/fault_labels.json
HELP
}

# ─── 入口 ─────────────────────────────────────────────────────────────────────
init_label_file

MODE=${1:-help}

case "$MODE" in
    auto)
        RUNTIME=${2:-$((7 * 24 * 3600))}
        scheduler_loop "$RUNTIME"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        [[ $# -lt 2 ]] && { show_help; exit 1; }
        manual_inject "$@"
        ;;
esac