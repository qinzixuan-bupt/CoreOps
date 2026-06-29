#!/bin/bash
cd /home/zhuchicheng/UERANSIM


# ── 1. 基础网络与切片配置 ──
NETWORK="hyper-5gc-net"
BASE_GNB_IP="10.100.200.200" # 基站起始 IP
BASE_AMF_IP="10.100.200.30"  # AMF 起始 IP

GNB_CONFIG_DIR="/home/zhuchicheng/UERANSIM/config/gnbs"
mkdir -p "$GNB_CONFIG_DIR"

# ── 2. 初始化关联数组 ──
declare -A GNB_IPS
declare -A AMF_IPS
declare -A GNB_TAC
declare -A GNB_NCI

echo ">>> 清理旧基站..."
docker rm -f $(docker ps -aq --filter "name=gnb-") 2>/dev/null

echo ">>> 生成 15 个 gNodeB 配置文件至 $GNB_CONFIG_DIR ..."
idx=0
for region in r1 r2 r3; do
  for num in 1 2 3 4 5; do
    id="${region}-${num}"
    
    GNB_IPS[$id]=$(awk -v ip="$BASE_GNB_IP" -v i="$idx" 'BEGIN{split(ip,a,"."); printf "%s.%s.%s.%d", a[1],a[2],a[3], a[4]+i}')
    
    # 计算 AMF IP
    AMF_IPS[$id]=$(awk -v ip="$BASE_AMF_IP" -v i="$idx" 'BEGIN{split(ip,a,"."); printf "%s.%s.%s.%d", a[1],a[2],a[3], a[4]+i}')
    
    # 计算 TAC
    tac=$(( (${region#r} - 1) * 50 + (num - 1) * 10 + 1 ))
    GNB_TAC[$id]=$tac
    
    # 计算 NCI
    GNB_NCI[$id]=$(printf "0x%010x" $(( 0x100 + idx )))
    
    idx=$((idx + 1))
  done
done

# ── 3. 批量生成 YAML 并启动容器 ──
for region in r1 r2 r3; do
  for num in 1 2 3 4 5; do
    id="${region}-${num}"
    
    cat > ${GNB_CONFIG_DIR}/gnb-${id}.yaml << YAML
mcc: '999'
mnc: '70'
nci: '${GNB_NCI[$id]}'
idLength: 32
tac: ${GNB_TAC[$id]}
linkIp: ${GNB_IPS[$id]}
ngapIp: ${GNB_IPS[$id]}
gtpIp: ${GNB_IPS[$id]}
amfConfigs:
  - address: ${AMF_IPS[$id]}
    port: 38412
slices:
  - sst: 1
    sd: '000001'
  - sst: 2
    sd: '000002'
  - sst: 3
    sd: '000003'
  - sst: 1
    sd: '000004'
ignoreStreamIds: true
YAML

    # 修改点：挂载时从指定目录读取
    docker run -d \
      --name gnb-${id} \
      --network $NETWORK \
      --ip ${GNB_IPS[$id]} \
      --cap-add=NET_ADMIN \
      -v ${GNB_CONFIG_DIR}/gnb-${id}.yaml:/config.yaml \
      ueransim:local \
      nr-gnb -c /config.yaml
      
    echo "  生成并启动 gnb-${id} -> AMF: ${AMF_IPS[$id]} (TAC: ${GNB_TAC[$id]})"
  done
done


echo ""
echo ">>> 等待 NGAP 接口建立..."
sleep 5

success_count=0
for region in r1 r2 r3; do
  for num in 1 2 3 4 5; do
    id="${region}-${num}"
    if docker logs gnb-${id} 2>&1 | grep -q "NG Setup procedure is successful"; then
      echo "  gnb-${id}: NGAP 已连接"
      success_count=$((success_count + 1))
    else
      echo "  gnb-${id}: 连接失败 (请检查日志: docker logs gnb-${id})"
    fi
  done
done

echo ""
echo "========================================="
echo " 基站启动完成: $success_count / 15 成功"
echo " 配置文件目录: $GNB_CONFIG_DIR"
echo "========================================="