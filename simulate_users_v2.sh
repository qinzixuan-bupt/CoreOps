#!/usr/bin/env bash
# launch_ues.sh

set -euo pipefail

# ──── 可调参数 ────────────────────────────────────────────────────
NR_UE=${NR_UE_BIN:-"/home/zhuchicheng/UERANSIM/build/nr-ue"}
CONFIG_DIR=${CONFIG_DIR:-"/home/zhuchicheng/UERANSIM/config/ues"}
LOG_DIR="./logs"
PID_DIR="./pids"
SLICES=("embb")
REG_SUCCESS_KEYWORD="PDU Session establishment is successful"


if [[ "${1:-}" == "--daemon" ]]; then
    shift
    mkdir -p "$LOG_DIR"
    DAEMON_LOG_FILE="$LOG_DIR/ue_launcher_$(date +%Y%m%d_%H%M%S).log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 准备启动 UE 仿真" > "$DAEMON_LOG_FILE"
    nohup bash "$0" "$@" >> "$DAEMON_LOG_FILE" 2>&1 &
    echo "   UE 仿真后台运行已启动"
    echo "   主进程 PID: $!"
    echo "   控制台监控日志: $DAEMON_LOG_FILE"
    exit 0
fi

usage() {
    echo "用法:"
    echo "  $0 {start|stop|status} [--config-dir DIR] [--nr-ue PATH]"
    echo "  $0 --daemon start   (后台长期运行，输出监控日志)"
    exit 1
}

CMD=${1:-""}
shift || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config-dir) CONFIG_DIR="$2"; shift 2 ;;
        --nr-ue)      NR_UE="$2";      shift 2 ;;
        *) echo "未知参数: $1"; usage ;;
    esac
done

[[ -z "$CMD" ]] && usage

# ──── 全局状态与信号处理 ──────────────────────────────────────────
RUNNING=true
PIDS_TO_KILL=()       
declare -A UE_CONFIG_MAP 

cleanup() {
    trap - SIGINT SIGTERM
    echo ""
    echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] 接收到中断信号，正在停止所有仿真 ==="
    RUNNING=false

    for pid in "${PIDS_TO_KILL[@]}"; do
        kill -9 "$pid" 2>/dev/null || true
    done
    
    echo "=== 停止 UE 进程 ==="
    if [[ -d "$PID_DIR" ]]; then
        for pidfile in "${PID_DIR}"/ue-*.pid; do
            [[ -f "$pidfile" ]] || continue
            pid=$(cat "$pidfile")
            kill -9 "$pid" 2>/dev/null || true
            rm -f "$pidfile"
        done
    fi
    
    echo "=== 环境清理完毕，安全退出 ==="
    exit 0
}
trap cleanup SIGINT SIGTERM

# ──── 智能网关获取函数 ────────────────────────────────────────────
get_target_ip() {
    local ue_name=$1
    local logfile="${LOG_DIR}/embb/${ue_name}.log"
    
    local ue_ip=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$logfile" 2>/dev/null | grep -v '127.0.0.1' | head -n 1 || true)

    if [[ -z "$ue_ip" ]]; then 
        echo "0.0.0.0"; 
        return; 
    fi

    local gateway_ip=$(echo "$ue_ip" | awk -F. '{print $1"."$2"."$3".1"}')
    echo "$gateway_ip"
}

behavior_simple_ping() {
    local ue_name=$1
    local logfile="${LOG_DIR}/embb/${ue_name}.log"
    local pidfile="${PID_DIR}/${ue_name}.pid"
    
    local nr_ue_pid
    if [[ -f "$pidfile" ]]; then
        nr_ue_pid=$(cat "$pidfile")
    else
        echo "[OFFLINE] $(date '+%H:%M:%S') - ${ue_name} PID文件丢失。"
        return 1
    fi

    # 1. 等待初始 PDU 建立成功
    local waited=0
    while $RUNNING; do
        if ! kill -0 "$nr_ue_pid" 2>/dev/null; then
            echo "[OFFLINE] $(date '+%H:%M:%S') - ${ue_name} 进程意外退出，判定为掉线。"
            return 1
        fi
        if grep -q "$REG_SUCCESS_KEYWORD" "$logfile" 2>/dev/null; then break; fi
        sleep 2; waited=$((waited+2))
        if (( waited > 60 )); then
            echo "[OFFLINE] $(date '+%H:%M:%S') - ${ue_name} 初始注册超时，判定为掉线。"
            kill -9 "$nr_ue_pid" 2>/dev/null || true
            rm -f "$pidfile"
            return 1
        fi
    done
    
    # 2. 获取网关 IP 
    local target="0.0.0.0"
    local ip_wait=0
    while $RUNNING; do
        target=$(get_target_ip "$ue_name")
        if [[ "$target" != "0.0.0.0" ]]; then
            break
        fi
        
        if ! kill -0 "$nr_ue_pid" 2>/dev/null; then
            echo "[OFFLINE] $(date '+%H:%M:%S') - ${ue_name} 进程在等待IP时意外退出。"
            return 1
        fi
        
        sleep 2
        ip_wait=$((ip_wait+2))
        if (( ip_wait > 30 )); then
        
            echo "[WARN] $(date '+%H:%M:%S') - ${ue_name} 等待IP超时..."
            target="0.0.0.0"
            break
        fi
    done
    
    # 3. 行为分支：Ping 
    if [[ "$target" == "0.0.0.0" ]]; then
        
        while $RUNNING; do
            if ! kill -0 "$nr_ue_pid" 2>/dev/null; then
                echo "[OFFLINE] $(date '+%H:%M:%S') - ${ue_name} (静默模式)进程消失。"
                return 1
            fi
            sleep 5
        done
    else
       
        echo "[ONLINE] $(date '+%H:%M:%S') - ${ue_name} 开始基线流量: ping $target"
        while $RUNNING; do
            if ! kill -0 "$nr_ue_pid" 2>/dev/null; then
                echo "[OFFLINE] $(date '+%H:%M:%S') - ${ue_name} UE 进程消失，判定为掉线。"
                return 1
            fi
            
           
            if ! ping -c 2 -W 1 -i 0.5 -s 500 "$target" >/dev/null 2>&1; then
                echo "[OFFLINE] $(date '+%H:%M:%S') - ${ue_name} Ping 中断，立刻执行物理断网(kill -9)阻止重连！"
               
                kill -9 "$nr_ue_pid" 2>/dev/null || true
                rm -f "$pidfile"
                return 1
            fi
        done
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────
start_ues() {
    echo "=== 启动 UE 进程 ==="
    mkdir -p "$PID_DIR"
    for dir in "${LOG_DIR}"/*/; do
        slice_name=$(basename "$dir")
        if [[ ! " ${SLICES[*]} " =~ " ${slice_name} " ]]; then rm -rf "$dir"; fi
    done

    for slice in "${SLICES[@]}"; do
        slice_cfg_dir="${CONFIG_DIR}/${slice}"
        log_slice_dir="${LOG_DIR}/${slice}"
        mkdir -p "$log_slice_dir"
        echo "── 切片: ${slice^^} ──"
        for cfg in "${slice_cfg_dir}"/ue-*.yaml; do
            [[ -f "$cfg" ]] || continue
            bname=$(basename "$cfg" .yaml)
            logfile="${log_slice_dir}/${bname}.log"
            pidfile="${PID_DIR}/${bname}.pid"
            if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
                echo "  [SKIP] ${bname} 已在运行"; continue
            fi
            > "$logfile"
           
            "$NR_UE" -c "$cfg" > "$logfile" 2>&1 &
            echo $! > "$pidfile"
            UE_CONFIG_MAP["$bname"]="$cfg"
            echo "  [OK]  ${bname}  PID=$!"
            sleep 0.2
        done
    done

    echo ""; echo "=== 等待核心网响应 ==="
    for wait_time in {1..6}; do
      ALL_READY=true
      for logfile in "${LOG_DIR}"/*/*.log; do
        [[ -f "$logfile" ]] || continue
        if ! grep -q "$REG_SUCCESS_KEYWORD" "$logfile"; then ALL_READY=false; break; fi
      done
      if $ALL_READY; then echo "所有 UE 已完成注册！"; break; fi
      echo "  等待中... ($((wait_time * 10))秒)"; sleep 10
    done

    echo "=== 注册状态报告 ==="
    SUCCESS_COUNT=0; SUCCESSFUL_UES=() 
    for slice in "${SLICES[@]}"; do
        for logfile in "${LOG_DIR}/${slice}"/*.log; do
            [[ -f "$logfile" ]] || continue
            bname=$(basename "$logfile" .log)
            if grep -q "$REG_SUCCESS_KEYWORD" "$logfile"; then
                echo "  [成功] ${bname}"; SUCCESSFUL_UES+=("$bname"); SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            else
                echo "  [失败] ${bname}"
            fi
        done
    done
    
    echo "----------------------------"
    echo "统计: $SUCCESS_COUNT 成功"
    if [ "$SUCCESS_COUNT" -eq 0 ]; then
      echo "所有设备注册失败，退出脚本。"; cleanup
    fi

    echo ""; echo "=== 分配行为==="
    BEHAVIOR_PIDS=()
    for ue_name in "${SUCCESSFUL_UES[@]}"; do
        behavior_simple_ping "$ue_name" & 
        BEHAVIOR_PIDS+=($!)
        echo "  [$ue_name] -> Ping 基线 (监控PID=$!)"
        PIDS_TO_KILL+=($!)
    done

    echo ""
    echo "UE 已就绪..."
    echo "----------------------------------------------------"
    
    # 主循环：监控存活数量
    ALIVE_COUNT=${#BEHAVIOR_PIDS[@]}
    while (( ALIVE_COUNT > 0 )) && $RUNNING; do
        TEMP_PIDS=()
        for pid in "${BEHAVIOR_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                TEMP_PIDS+=("$pid")
            fi
        done
        BEHAVIOR_PIDS=("${TEMP_PIDS[@]}")
        ALIVE_COUNT=${#BEHAVIOR_PIDS[@]}
        
        if (( ALIVE_COUNT > 0 )); then
            echo "[$(date '+%H:%M:%S')] 当前存活 UE 数量: $ALIVE_COUNT"
            sleep 5
        fi
    done

    if (( ALIVE_COUNT == 0 )); then
        echo ""
        echo " [$(date '+%Y-%m-%d %H:%M:%S')] 所有 UE 均已掉线，数据集生成完毕，任务自动结束。"
    fi
}

stop_ues() {
    echo "=== 停止所有 UE 进程 ==="
    [[ -d "$PID_DIR" ]] || { echo "无 PID 目录。"; return 0; }
    count=0
    for pidfile in "${PID_DIR}"/ue-*.pid; do
        [[ -f "$pidfile" ]] || continue
        pid=$(cat "$pidfile"); bname=$(basename "$pidfile" .pid)
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid"; echo "  [STOP] ${bname}  PID=${pid}"; count=$((count+1))
        fi
        rm -f "$pidfile"
    done
    echo "已停止 ${count} 个 UE 进程。"
}

status_ues() {
    echo "=== UE 进程状态 ==="
    [[ -d "$PID_DIR" ]] || { echo "无 PID 目录。"; exit 0; }
    running=0; dead=0
    for pidfile in "${PID_DIR}"/ue-*.pid; do
        [[ -f "$pidfile" ]] || continue
        pid=$(cat "$pidfile"); bname=$(basename "$pidfile" .pid)
        if kill -0 "$pid" 2>/dev/null; then
            echo "  [RUN]  ${bname}  PID=${pid}"; running=$((running+1))
        else
            echo "  [DEAD] ${bname}  PID=${pid}"; dead=$((dead+1))
        fi
    done
    echo "运行中: ${running}，已停止: ${dead}"
}

# ──────────────────────────────────────────────────────────────────
case "$CMD" in
    start)  start_ues  ;;
    stop)   stop_ues   ;;
    status) status_ues ;;
    *) usage ;;
esac