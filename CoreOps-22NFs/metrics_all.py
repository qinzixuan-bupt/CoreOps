import requests
import time
import csv
import os
from datetime import datetime

PROMETHEUS_URL = "http://localhost:9091/api/v1/query"
CSV_FILENAME = "realtime_5gc_metrics_benchmark.csv"

def init_csv():
    """初始化 CSV 表头"""
    if not os.path.exists(CSV_FILENAME):
        with open(CSV_FILENAME, mode='w', newline='') as file:
            writer = csv.writer(file)
            # 采用标准长表结构，完美适配时序模型训练和数据库 SQL 查询
            writer.writerow(['timestamp', 'readable_time', 'nf_name', 'metric_name', 'metric_value'])
        print(f"已创建全量指标实时文件: {CSV_FILENAME}")

def fetch_all_instant_metrics():
    """使用标签匹配，拉取该容器的所有指标"""
    # 终极查询语句：不指定具体的指标名，只指定容器名称前缀
    query = '{name=~"clab-hn-5gc-bench.*"}'
    
    try:
        response = requests.get(PROMETHEUS_URL, params={'query': query})
        data = response.json()
        
        if data.get('status') == 'success':
            results = data['data']['result']
            
            with open(CSV_FILENAME, mode='a', newline='') as file:
                writer = csv.writer(file)
                
                for result in results:
                    metric_labels = result['metric']
                    
                    # 1. 从内部标签 __name__ 中提取真实的指标名称
                    metric_name = metric_labels.get('__name__', 'unknown')
                    
                    # 2. 提取网元名称并做精简处理
                    raw_name = metric_labels.get('name', 'unknown')
                    nf_name = raw_name.replace('clab-hn-5gc-bench-', '')
                    
                    # 3. 提取时间和数值
                    timestamp = float(result['value'][0])
                    metric_value = float(result['value'][1])
                    readable_time = datetime.fromtimestamp(timestamp).strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]
                    
                    # 4. 写入全量特征
                    writer.writerow([timestamp, readable_time, nf_name, metric_name, metric_value])
                    
    except Exception as e:
        print(f"采集出错: {e}")

if __name__ == "__main__":
    print("🚀 开始全量抓取 5GC 所有容器指标... (按 Ctrl+C 停止)")
    init_csv()
    
    try:
        while True:
            # 记录抓取一次耗时，确保不会因为数据量过大导致严重延迟
            start_time = time.time()
            fetch_all_instant_metrics()
            cost_time = time.time() - start_time
            
            # 动态调整 sleep 时间，尽量保持 1 秒 1 次的稳定采样率
            sleep_time = max(0, 1.0 - cost_time)
            time.sleep(sleep_time) 
            
    except KeyboardInterrupt:
        print("\n⏹️ 停止实时采集。")