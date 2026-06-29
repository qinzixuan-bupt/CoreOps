#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
#  hn-5gc-metrics-collector-v3 (Enhanced Observability)
# ══════════════════════════════════════════════════════════════════════════════

set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# 配置
# ─────────────────────────────────────────────────────────────────────────────

OUTPUT_DIR="${OUTPUT_DIR:-/home/zhuchicheng/metrics}"
PER_NF_DIR="${OUTPUT_DIR}/per_nf"

INTERVAL="${1:-15}"
METRICS_PORT="${2:-9090}"

FAULT_LABEL_FILE="${FAULT_LABEL_FILE:-./fault_logs/fault_labels.json}"

MAX_FAIL_BEFORE_DOWN=3

mkdir -p "$OUTPUT_DIR"
mkdir -p "$PER_NF_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# 自动发现网元 IP
# ─────────────────────────────────────────────────────────────────────────────

TARGET_NFS=(
    amf-r1-1 amf-r1-2 amf-r1-3 amf-r1-4 amf-r1-5 amf-r2-1 amf-r2-2 amf-r2-3 amf-r2-4 amf-r2-5 amf-r3-1 amf-r3-2 amf-r3-3 amf-r3-4 amf-r3-5
    ausf-1 ausf-2 ausf-3 ausf-4 ausf-5 bsf-1 bsf-2 bsf-3 nrf nssf pcf-1 pcf-2 pcf-3 pcf-4 pcf-5 pcf-6
    smf-s1-1 smf-s1-2 smf-s1-3 smf-s1-4 smf-s1-5 smf-s2-1 smf-s2-2 smf-s2-3 smf-s2-4 smf-s2-5 smf-s3-1 smf-s3-2 smf-s3-3 smf-s3-4 smf-s3-5 smf-s4-1 smf-s4-2 smf-s4-3 smf-s4-4 smf-s4-5
    udm-1 udm-2 udm-3 udm-4 udm-5 udr-1 udr-2 udr-3 udr-4 udr-5
    upf-core-1 upf-core-2 upf-core-3 upf-core-4 upf-core-5 upf-core-6 upf-edge-1 upf-edge-2 upf-edge-3 upf-edge-4 upf-edge-5 upf-edge-6 upf-edge-7 upf-edge-8 upf-edge-9 upf-edge-10
    upf-local-1 upf-local-2 upf-local-3 upf-local-4 upf-local-5 upf-local-6 upf-local-7 upf-local-8 upf-local-9 upf-local-10 upf-regional-21 upf-regional-22 upf-regional-23
    upf-regional-24 upf-regional-25 upf-regional-26 upf-regional-27 upf-regional-28 upf-regional-29 upf-regional-30
)

declare -A NF_IPS

discover_nf_ips() {
    local container_prefix="clab-hyper-5gc-hybrid-"
    local network_name="${NETWORK_NAME:-clab-hyper-5gc-hybrid}"

    log "正在自动发现网元IP..."

    local found_count=0
    for short_name in "${TARGET_NFS[@]}"; do
        local full_name="${container_prefix}${short_name}"

        if ! docker ps --format '{{.Names}}' | grep -qx "$full_name"; then
            log_warn "容器 $full_name 未运行，跳过"
            continue
        fi

        local ip=""
        if [[ -n "$network_name" ]]; then
            ip=$(docker inspect -f "{{range .NetworkSettings.Networks}}{{if eq .NetworkID \"$network_name\"}}{{.IPAddress}}{{end}}{{end}}" "$full_name" 2>/dev/null)
        fi
        if [[ -z "$ip" ]]; then
            ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$full_name" 2>/dev/null)
        fi

        if [[ -n "$ip" && "$ip" != "0.0.0.0" ]]; then
            NF_IPS["$short_name"]="$ip"
            log "发现网元: $short_name -> $ip"
            ((found_count++))
        else
            log_warn "无法获取容器 $full_name 的 IP，跳过"
        fi
    done

    if [[ $found_count -eq 0 ]]; then
        log_warn "未发现任何有效网元，采集将无法进行"
        return 1
    fi

    log "共发现 $found_count 个网元"
}

# ─────────────────────────────────────────────────────────────────────────────
# 指标白名单
# ─────────────────────────────────────────────────────────────────────────────

METRIC_WHITELIST=(
    "process_cpu_seconds_total"
    "process_resident_memory_bytes"
    "process_virtual_memory_bytes"
    "process_start_time_seconds"
    "process_open_fds"

    "go_goroutines"
    "go_threads"
    "go_gc_duration_seconds"
    "go_memstats_alloc_bytes"
    "go_memstats_heap_inuse_bytes"
    "go_memstats_gc_cpu_fraction"
    "go_memstats_num_gc"

    "http_request_duration_seconds"
    "http_requests_total"

    "open5gs_"
    "nrf_"
    "nnrf_"
    "net_conntrack_"
    "grpc_"
    "tcp_"

    "node_netstat_"
    "node_network_"
)

# ─────────────────────────────────────────────────────────────────────────────
# 运行时状态
# ─────────────────────────────────────────────────────────────────────────────

declare -A NF_CSV_PATH
declare -A NF_COLUMNS
declare -A NF_FAIL_COUNT
declare -A NF_STATUS

declare -A PREV_METRIC
declare -A PREV_START_TIME

# 用于 Jitter 计算的滑动窗口历史记录
declare -A LATENCY_HISTORY

RUN_TS=$(date +%Y%m%d_%H%M%S)

STATE_FILE="${OUTPUT_DIR}/collector_state.json"
GLOBAL_MATRIX="${OUTPUT_DIR}/global_matrix.csv"
FAULT_WINDOW_FILE="${OUTPUT_DIR}/aligned_fault_window.json"

ROUND=0

# ─────────────────────────────────────────────────────────────────────────────
# 工具函数
# ─────────────────────────────────────────────────────────────────────────────

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

log_warn() {
    echo "[$(date '+%H:%M:%S')] WARNING: $*" >&2
}

iso_now() {
    date +"%Y-%m-%dT%H:%M:%S+08:00"
}

build_whitelist_pattern() {
    local p=""
    for prefix in "${METRIC_WHITELIST[@]}"; do
        [[ -z "$p" ]] && p="^(${prefix}" || p="${p}|${prefix}"
    done
    p="${p})"
    echo "$p"
}

WHITELIST_PATTERN=$(build_whitelist_pattern)

is_whitelisted() {
    [[ "$1" =~ $WHITELIST_PATTERN ]]
}

flatten_key() {
    local line="$1"
    if [[ "$line" =~ ^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?[[:space:]] ]]; then
        local name="${BASH_REMATCH[1]}"
        local labels="${BASH_REMATCH[2]}"
        if [[ -z "$labels" ]]; then
            echo "$name"
        else
            echo "${name}${labels//,/;}"
        fi
    fi
}

extract_value() {
    local line="$1"
    if [[ "$line" =~ [[:space:]]([+\-]?([0-9]*\.?[0-9]+([eE][+\-]?[0-9]+)?|NaN|\+Inf|\-Inf))([[:space:]].*)?$ ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

safe_rate() {
    local cur="$1"
    local prev="$2"
    # 防止首次无前值或负增长导致异常
    awk -v c="$cur" -v p="$prev" -v i="$INTERVAL" '
    BEGIN{
        d=c-p
        if(d<0) d=0
        if(i==0) i=1
        printf "%.6f", d/i
    }'
}

# ─────────────────────────────────────────────────────────────────────────────
# scrape 核心
# ─────────────────────────────────────────────────────────────────────────────

scrape_nf() {
    local nf="$1"
    local ip="${NF_IPS[$nf]}"

    local begin
    begin=$(date +%s%3N)

    local raw
    raw=$(curl -sf --connect-timeout 3 --max-time 8 "http://${ip}:${METRICS_PORT}/metrics" 2>/dev/null)
    local rc=$?

    local end
    end=$(date +%s%3N)
    local latency_ms=$(( end - begin ))

    if (( rc != 0 )) || [[ -z "$raw" ]]; then
        return 1
    fi

    echo "__scrape_latency_ms=${latency_ms}"

    local line key val base_name
    while IFS= read -r line; do
        [[ "$line" =~ ^# ]] && continue
        [[ -z "$line" ]] && continue

        base_name="${line%%\{*}"
        base_name="${base_name%% *}"
        is_whitelisted "$base_name" || continue

        key=$(flatten_key "$line")
        val=$(extract_value "$line")

        [[ -n "$key" && -n "$val" ]] && echo "${key}=${val}"
    done <<< "$raw"
}

diagnose_network_block() {
    local nf="$1"
    local container="clab-hn-5gc-bench-${nf}"
    
    local internal_ok=0
    local has_ip=0

    # 1. 探测容器内部进程是否还活着
    if docker exec "$container" curl -sf -m 2 http://127.0.0.1:${METRICS_PORT}/metrics > /dev/null 2>&1; then
        internal_ok=1
    fi

    # 2. 探测容器是否还有外部 IP
    local current_ip
    current_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container" 2>/dev/null)
    if [[ -n "$current_ip" && "$current_ip" != "0.0.0.0" ]]; then
        has_ip=1
    fi

    # 3. 逻辑判定
    if (( internal_ok == 1 && has_ip == 1 )); then
        echo "network_inbound_drop_detected=1"
    else
        echo "network_inbound_drop_detected=0"
    fi
}

collect_tc_qdisc() {
    local nf="$1"
    local container="clab-hn-5gc-bench-${nf}"
    
    # 抓取 eth0 的 qdisc 配置
    local tc_output
    tc_output=$(docker exec "$container" tc -s qdisc show dev eth0 2>/dev/null)
    
    if [[ -z "$tc_output" ]]; then
        echo "tc_tbf_rate_bps=0"
        return
    fi

    # 匹配注入器注入的 tbf rate xxxKbit 或 xxxMbit 格式，并转换为 bps
    local rate_bps
    rate_bps=$(echo "$tc_output" | awk '
    /rate [0-9]+[KkMmGg][bB][iI][tT]/ {
        for(i=1;i<=NF;i++) {
            if($i == "rate") {
                val=$(i+1)
                gsub(/[a-zA-Z]/, "", val)
                unit=$(i+1)
                if(unit ~ /M/) mult=1000000
                else if(unit ~ /K/) mult=1000
                else if(unit ~ /G/) mult=1000000000
                else mult=1
                printf "%.0f", val * mult
                exit
            }
        }
    }')
    
    # 如果没匹配到限速规则，说明是无限速
    echo "tc_tbf_rate_bps=${rate_bps:-0}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 内核网络态 & Socket 状态
# ─────────────────────────────────────────────────────────────────────────────

collect_kernel_netstat() {
    local nf="$1"
    local container="clab-hn-5gc-bench-${nf}"
    docker exec "$container" bash -c 'cat /proc/net/netstat 2>/dev/null' 2>/dev/null | awk '
    /TcpExt:/{
        if(seen==0){ for(i=2;i<=NF;i++)k[i]=$i; seen=1 }
        else{ for(i=2;i<=NF;i++) print "kernel_tcp_"k[i]"="$i }
    }'
}

collect_socket_state() {
    local nf="$1"
    local container="clab-hn-5gc-bench-${nf}"
    docker exec "$container" bash -c 'ss -tan 2>/dev/null' 2>/dev/null | awk '
    BEGIN{ est=0; syn=0; timewait=0; closewait=0 }
    /ESTAB/{est++} /SYN-SENT/{syn++} /TIME-WAIT/{timewait++} /CLOSE-WAIT/{closewait++}
    END{
        print "socket_ESTAB="est
        print "socket_SYN_SENT="syn
        print "socket_TIME_WAIT="timewait
        print "socket_CLOSE_WAIT="closewait
    }'
}

# ─────────────────────────────────────────────────────────────────────────────
# CSV 初始化 & 写行
# ─────────────────────────────────────────────────────────────────────────────

init_nf_csv() {
    local nf="$1"
    local csv="${PER_NF_DIR}/${nf}_${RUN_TS}.csv"
    NF_CSV_PATH["$nf"]="$csv"
    NF_COLUMNS["$nf"]=""
    NF_FAIL_COUNT["$nf"]=0
    NF_STATUS["$nf"]="unknown"
}

write_row() {
    local nf="$1"
    local timestamp="$2"
    shift 2

    local -A kv
    local pair k v
    for pair in "$@"; do
        k="${pair%%=*}"
        v="${pair#*=}"
        kv["$k"]="$v"
    done

    local derived_pairs=()
    for k in "${!kv[@]}"; do
        v="${kv[$k]}"
        # 匹配 _total 结尾的指标，或内核 TCP 拓展指标
        if [[ "$k" == *"_total" ]] || [[ "$k" == "kernel_tcp_"* ]]; then
            local prev_key="${nf}_${k}"
            local prev_val="${PREV_METRIC[$prev_key]:-0}"
            local rate_val=$(safe_rate "$v" "$prev_val")
            derived_pairs+=("${k}_rate=${rate_val}")
            PREV_METRIC["$prev_key"]="$v"
        fi
    done
    
    # 将派生指标合并到主字典
    for pair in "${derived_pairs[@]}"; do
        k="${pair%%=*}"
        v="${pair#*=}"
        kv["$k"]="$v"
    done

    # 处理动态新增列
    local csv="${NF_CSV_PATH[$nf]}"
    local known="${NF_COLUMNS[$nf]}"
    local new_cols=()

    for k in "${!kv[@]}"; do
        if [[ ";${known};" != *";${k};"* ]]; then
            new_cols+=("$k")
        fi
    done

    if (( ${#new_cols[@]} > 0 )); then
        IFS=$'\n' read -r -d '' -a sorted < <(printf '%s\n' "${new_cols[@]}" | sort && printf '\0')
        local appended=$(IFS=';'; echo "${sorted[*]}")

        if [[ -z "$known" ]]; then
            NF_COLUMNS["$nf"]="$appended"
        else
            NF_COLUMNS["$nf"]="${known};${appended}"
        fi

        local header="timestamp;scrape_ok;restart_detected;${NF_COLUMNS[$nf]}"
        if [[ ! -f "$csv" ]]; then
            echo "$header" > "$csv"
        else
            local tmp=$(mktemp)
            echo "$header" > "$tmp"
            tail -n +2 "$csv" >> "$tmp"
            mv "$tmp" "$csv"
        fi
    fi

    # restart detect
    local restart=0
    local cur="${kv[process_start_time_seconds]:-}"
    local prev="${PREV_START_TIME[$nf]:-}"
    if [[ -n "$cur" && -n "$prev" ]]; then
        if awk "BEGIN{exit ($cur==$prev)}"; then restart=1; fi
    fi
    [[ -n "$cur" ]] && PREV_START_TIME["$nf"]="$cur"

    # build row
    local row="${timestamp};1;${restart}"
    IFS=';' read -r -a cols <<< "${NF_COLUMNS[$nf]}"
    local c
    for c in "${cols[@]}"; do
        row="${row};${kv[$c]:-}"
    done

    echo "$row" >> "$csv"
}

write_down_row() {
    local nf="$1"
    local timestamp="$2"
    local csv="${NF_CSV_PATH[$nf]}"
    
    if [[ ! -f "$csv" ]]; then
        echo "timestamp;scrape_ok;restart_detected" > "$csv"
    fi

    local row="${timestamp};0;0"
    if [[ -n "${NF_COLUMNS[$nf]}" ]]; then
        IFS=';' read -r -a cols <<< "${NF_COLUMNS[$nf]}"
        for _ in "${cols[@]}"; do row="${row};"; done
    fi
    echo "$row" >> "$csv"
}

# ─────────────────────────────────────────────────────────────────────────────
# fault 对齐 & global matrix
# ─────────────────────────────────────────────────────────────────────────────

align_fault_window() {
    [[ ! -f "$FAULT_LABEL_FILE" ]] && return
    python3 - "$FAULT_LABEL_FILE" "$FAULT_WINDOW_FILE" <<'PYEOF'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src,'r') as f: data=json.load(f)
active=[{"fault_id":x.get("fault_id"),"fault_type":x.get("fault_type"),"targets":x.get("targets"),"start_time":x.get("start_time"),"end_time":x.get("end_time")} for x in data.get("run_history",[])]
with open(dst,'w') as f: json.dump(active,f,indent=2)
PYEOF
}

append_global_matrix() {
    local timestamp="$1"; shift
    local row="$timestamp"
    for x in "$@"; do row="${row};${x}"; done
    if [[ ! -f "$GLOBAL_MATRIX" ]]; then echo "timestamp;data" > "$GLOBAL_MATRIX"; fi
    echo "$row" >> "$GLOBAL_MATRIX"
}

# ─────────────────────────────────────────────────────────────────────────────
# collect once
# ─────────────────────────────────────────────────────────────────────────────

collect_once() {
    ROUND=$(( ROUND + 1 ))
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    local global_data=()

    for nf in "${!NF_IPS[@]}"; do
        [[ -z "${NF_CSV_PATH[$nf]:-}" ]] && init_nf_csv "$nf"

        local pairs=()
        local scrape_success=0

        # 1. 尝试正常抓取
        while IFS= read -r line; do
            [[ -n "$line" ]] && pairs+=("$line")
        done < <(scrape_nf "$nf")

        if (( ${#pairs[@]} > 0 )); then
            scrape_success=1
            
            local current_latency=""
            for p in "${pairs[@]}"; do
                if [[ "$p" == __scrape_latency_ms=* ]]; then
                    current_latency="${p#__scrape_latency_ms=}"
                    break
                fi
            done

            if [[ -n "$current_latency" ]]; then
                # 维护滑动窗口 
                local hist="${LATENCY_HISTORY[$nf]:-}"
                hist="$hist $current_latency"
                # 裁剪只保留最后 5 个
                hist=$(echo "$hist" | awk '{for(i=NF-4;i<=NF;i++) if(i>0) printf "%s ", $i}')
                LATENCY_HISTORY["$nf"]="$hist"
                
                # 计算方差作为 Jitter 指标
                local jitter=$(echo "$hist" | awk '{
                    n=0; sum=0; for(i=1;i<=NF;i++) {sum+=$i; n++} 
                    if(n==0){print "0.00"; exit}
                    mean=sum/n; var=0; 
                    for(i=1;i<=NF;i++) var+=($i-mean)^2; 
                    printf "%.2f", sqrt(var/n)
                }')
                pairs+=("scrape_latency_jitter_ms=${jitter}")
            fi

            while IFS= read -r line; do
                [[ -n "$line" ]] && pairs+=("$line")
            done < <(collect_tc_qdisc "$nf")

            # 附加内核态指标
            while IFS= read -r line; do [[ -n "$line" ]] && pairs+=("$line"); done < <(collect_kernel_netstat "$nf")
            while IFS= read -r line; do [[ -n "$line" ]] && pairs+=("$line"); done < <(collect_socket_state "$nf")

            write_row "$nf" "$ts" "${pairs[@]}"
            NF_FAIL_COUNT["$nf"]=0
            NF_STATUS["$nf"]="up"
            global_data+=("${nf}=UP")
        else
            # 2. 抓取失败处理
            NF_FAIL_COUNT["$nf"]=$(( ${NF_FAIL_COUNT[$nf]:-0} + 1 ))
            if (( ${NF_FAIL_COUNT[$nf]} >= MAX_FAIL_BEFORE_DOWN )); then
                NF_STATUS["$nf"]="down"
            fi
            
            while IFS= read -r line; do
                [[ -n "$line" ]] && pairs+=("$line")
            done < <(diagnose_network_block "$nf")

            write_down_row "$nf" "$ts"
            global_data+=("${nf}=DOWN")
        fi
    done

    append_global_matrix "$ts" "${global_data[@]}"
    align_fault_window
    log "round=${ROUND} collected"
}

# ─────────────────────────────────────────────────────────────────────────────
# state flush & exit
# ─────────────────────────────────────────────────────────────────────────────

flush_state() {
python3 - "$STATE_FILE" "${!NF_STATUS[@]}" "---" "${NF_STATUS[@]}" <<'PYEOF'
import json, sys, datetime
args=sys.argv[2:]
idx=args.index("---")
names=args[:idx]
vals=args[idx+1:]
obj=dict(zip(names,vals))
tz_bj = datetime.timezone(datetime.timedelta(hours=8))
out={"updated_at": datetime.datetime.now(tz_bj).strftime("%Y-%m-%dT%H:%M:%S+08:00"), "nf_status":obj}
with open(sys.argv[1],'w') as f: json.dump(out,f,indent=2)
PYEOF
}

on_exit() {
    echo ""
    log "collector stopped"
    log "output: $OUTPUT_DIR"
}
trap on_exit EXIT SIGINT SIGTERM

# ─────────────────────────────────────────────────────────────────────────────
# 启动
# ─────────────────────────────────────────────────────────────────────────────

discover_nf_ips
if [[ ${#NF_IPS[@]} -eq 0 ]]; then
    log_warn "没有发现任何有效网元，脚本退出"
    exit 1
fi

log "═══════════════════════════════════════"
log "5GC Metrics Collector V3 (AIOps Enhanced)"
log "interval=${INTERVAL}s"
log "nf_count=${#NF_IPS[@]}"
log "output=$OUTPUT_DIR"
log "═══════════════════════════════════════"

while true; do
    collect_once
    flush_state
    sleep "$INTERVAL"
done