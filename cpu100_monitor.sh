#!/bin/bash

# 设置监控时间间隔、阈值和重置时间间隔
interval=5  # 监控时间间隔（秒）
threshold=90  # CPU 使用率阈值（百分比）
reset_interval=60  # 重置计数器的时间间隔（秒）

# 钉钉 Webhook URL
webhook_url="https://oapi.dingtalk.com/robot/send?access_token=1a2457391815d5bcec7192d315e04a1816cd158329eaad5b76380441200a21e0"

# Elasticsearch配置
elasticsearch_uri="http://192.168.3.231:9200"
index_name="cpu_usage_logs"

# 获取Java应用的进程ID和主类
get_java_processes() {
  jps -l | awk '{print $1, $2}'
}

# 获取线程堆栈信息
get_thread_stack_traces() {
  pid=$1
  jstack_output=$(jstack $pid)
  echo "$jstack_output"
}

# 发送钉钉消息
send_dingding_message() {
  message=$1
  curl -X POST -H "Content-Type: application/json" -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"$message\"}}" "$webhook_url"
}

# 将日志写入Elasticsearch
write_to_elasticsearch() {
  log=$1
  curl -X POST -H "Content-Type: application/json" -d "$log" "$elasticsearch_uri/$index_name/_doc"
}

# 生成唯一的traceId
generate_trace_id() {
  trace_id=$(openssl rand -hex 16)
  echo "$trace_id"
}

# 创建索引
create_index() {
  echo "Creating index $index_name..."
  create_index_request='
  {
    "mappings": {
      "properties": {
        "message": {
          "type": "text"
        },
        "traceId": {
          "type": "keyword"
        },
        "timestamp": {
          "type": "date"
        },
        "threadStackTraces": {
          "type": "text"
        }
      }
    }
  }
  '
  curl -XPUT "$elasticsearch_uri/$index_name" -H 'Content-Type: application/json' -d "$create_index_request"
  echo "Index created."
}

# 检查索引是否存在
check_index_exists() {
  echo "Checking if index $index_name exists..."
  curl -s -o /dev/null -w "%{http_code}" -XHEAD "$elasticsearch_uri/$index_name"
}

# 获取所有Java应用的列表
java_processes=$(get_java_processes)

# 如果没有Java应用，则退出脚本
if [ -z "$java_processes" ]; then
  echo "No Java applications found. Exiting."
  exit 1
fi

# 显示所有Java应用的列表
echo "Java applications found:"
echo "$java_processes"
echo "Please enter the process ID of the Java application you want to monitor:"
read pid

# 检查输入的进程ID是否存在
valid_pid=false
for process in $java_processes; do
  if [ "$process" == "$pid" ]; then
    valid_pid=true
    break
  fi
done

if ! $valid_pid; then
  echo "Invalid process ID. Exiting."
  exit 1
fi

# 获取应用名
app_name=$(echo "$java_processes" | awk -v pid=$pid '$1 == pid {print $2}')

# 输出当前获取的应用名
echo "Monitoring CPU usage of Java application: $app_name"

# 检查索引是否存在
if [ "$(check_index_exists)" == "200" ]; then
  echo "Index $index_name already exists."
else
  # 创建索引
  create_index
fi

# 初始化计数器和时间戳
count=0
last_alert_time=$(date +%s)

# 循环监控
while true; do
  # 获取当前时间
  current_time=$(date +%s)

  # 计算时间差
  elapsed_time=$((current_time - last_alert_time))

  # 如果时间差大于等于重置时间间隔，则重置计数器
  if [ $elapsed_time -ge $reset_interval ]; then
    count=0
    last_alert_time=$current_time
  fi

  # 获取 CPU 使用率
  cpu_usage=$(top -b -n 1 -p $pid | awk -v threshold=$threshold 'NR>7 { if ($1 == pid) { if ($9 >= threshold) print $9 } }' pid=$pid)

  # 判断 CPU 使用率是否超过阈值
  if [[ -n $cpu_usage ]]; then
    if [ $count -lt 2 ]; then
      echo "CPU usage of Java app is $cpu_usage%"

      # 获取线程堆栈信息
      thread_stack_traces=$(get_thread_stack_traces $pid)

      # 将线程堆栈输出到文件
      output_file="jstack_output_$(date +"%Y%m%d%H%M%S").txt"
      echo "$thread_stack_traces" > $output_file
      echo "Thread stack traces saved to $output_file"

      # 生成唯一的traceId
      trace_id=$(generate_trace_id)

      # 构建钉钉消息内容
      message="CPU Usage Alert\n\nCPU usage of Java app is $cpu_usage%\n\nTrace ID: $trace_id"

      # 发送钉钉消息
      send_dingding_message "$message"

      # 构建日志数据
      timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      log="{\"message\":\"$message\",\"traceId\":\"$trace_id\",\"timestamp\":\"$timestamp\",\"threadStackTraces\":\"$thread_stack_traces\"}"

      # 写入Elasticsearch日志
      write_to_elasticsearch "$log"

      count=$((count + 1))
      last_alert_time=$current_time
    fi
  fi

  # 等待指定时间间隔
  sleep $interval
done
